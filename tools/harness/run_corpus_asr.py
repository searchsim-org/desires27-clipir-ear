"""Corpus WER on real far-field speech (Mac-tier recognizer evaluation).

Decodes every oracle segment of a pinned corpus and reports corpus-level WER (total edits / total reference words)
with a 95 % bootstrap CI over meetings, plus the real-time factor (decode wall time / audio duration).
Systems: `zipformer` = `EarCLI asr-segments` (the phone's streaming Zipformer and settings); `whisper-large-v3-turbo` =
the Mac tier's offline candidate, whisper.cpp `whisper-cli` (Homebrew, Metal) with its default decoding (beam 5),
one 30 s window per segment; `ct2-whisper-large-v3-turbo` = the same model through CTranslate2 on CPU (cluster runs).

Usage: uv run --project mac/earbridge python tools/harness/run_corpus_asr.py --corpus ami-sdm-test
       [--system zipformer|whisper-large-v3-turbo|ct2-whisper-large-v3-turbo] [--rms-dbfs -23] [--limit N]
Writes docs/evidence/raw/asr_<corpus>[_<system>]_<level>.json and .build/corpus/<corpus>/hyp[_<system>][_norm].jsonl.
Sharded (tools/cluster/whisper-ami-job.yaml): each pod runs `--meeting M`; `--from-shards DIR` then scores the pods'
hyp/summary files without decoding (RTF = summed shard decode time / summed audio, i.e. one stream).
Normalisation: tools/harness/wer.py `normalize` on both sides (lower case, apostrophes dropped, letters and digits only,
numbers 0–20 and tens spelled out). Not the Whisper normaliser: its PyPI port has no stated licence (LICENSES.md).
"""

import argparse
import array
import json
import os
import platform
import random
import struct
import subprocess
import sys
import time
import wave
from collections import defaultdict
from pathlib import Path

import pyarrow.parquet as pq

sys.path.insert(0, str(Path(__file__).parent))
from wer import normalize  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
MODELS = Path.home() / "Library/Application Support/ClipIREar/models"
EARCLI = ROOT / ".build/release/EarCLI"
# pinned: tools/models/sources.json whisper-large-v3-turbo
WHISPER = MODELS / "whisper/ggml-large-v3-turbo.bin"
CT2 = (
    MODELS / "faster-whisper-large-v3-turbo"
)  # pinned: sources.json faster-whisper-large-v3-turbo-*
CORPORA = {
    "ami-sdm-test": MODELS / "ami-sdm-test"
}  # parquet dirs pinned in tools/models/sources.json


def pcm16_from_wav(b: bytes) -> bytes:
    """RIFF WAV (PCM16 or float32, mono, 16 kHz) → raw PCM16 LE."""
    pos, fmt, rate = 12, None, None
    while pos < len(b):
        cid, size = b[pos : pos + 4], struct.unpack("<I", b[pos + 4 : pos + 8])[0]
        body = b[pos + 8 : pos + 8 + size]
        if cid == b"fmt ":
            fmt, channels, rate = struct.unpack("<HHI", body[:8])
            assert channels == 1, "mono expected"
        elif cid == b"data":
            assert rate == 16_000, f"16 kHz expected, got {rate}"
            if fmt == 1:
                return body
            assert fmt == 3, f"unsupported WAV format {fmt}"
            f = array.array("f", body)
            return array.array("h", (max(-32768, min(32767, int(x * 32767))) for x in f)).tobytes()
        pos += 8 + size + (size & 1)
    raise ValueError("no data chunk")


def edits(ref: list[str], hyp: list[str]) -> int:
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h))
        prev = cur
    return prev[-1]


def host() -> str:
    if platform.system() == "Darwin":
        return subprocess.run(
            ["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True
        ).stdout.strip()
    cpu = [
        ln.split(":", 1)[1].strip()
        for ln in Path("/proc/cpuinfo").read_text().splitlines()
        if ln.startswith("model name")
    ]
    return f"{cpu[0] if cpu else platform.machine()}, {os.environ.get('WHISPER_THREADS', '4')} threads"  # fmt: skip


def decode_zipformer(pcms: dict[str, Path]) -> tuple[list[dict], str, float]:
    manifest = "".join(f"{i}\t{p}\n" for i, p in pcms.items())
    t0 = time.monotonic()
    out = subprocess.run(
        [str(EARCLI), "asr-segments"], input=manifest, capture_output=True, text=True, check=True
    )
    wall = time.monotonic() - t0
    return (
        [json.loads(line) for line in out.stdout.splitlines()],
        "sherpa:zipformer-en-2023-06-26",
        wall,
    )


def decode_whisper(pcms: dict[str, Path]) -> tuple[list[dict], str, float]:
    wavs = {}
    for i, p in pcms.items():  # whisper-cli reads WAV only; written next to the PCM and kept
        wavs[i] = p.with_suffix(".wav")
        if not wavs[i].exists():
            with wave.open(str(wavs[i]), "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(16_000)
                w.writeframes(p.read_bytes())
    ids = list(wavs)
    # resume: segments with a transcript from an interrupted run are skipped; RTF covers only what this run decodes
    todo = [i for i in ids if not Path(f"{wavs[i]}.txt").exists()]
    t0 = time.monotonic()
    # batches keep argv under ARG_MAX; model reload per batch is ~1 s
    for k in range(0, len(todo), 500):
        batch = [str(wavs[i]) for i in todo[k : k + 500]]
        subprocess.run(["whisper-cli", "-m", str(WHISPER), "-l", "en", "-t", os.environ.get("WHISPER_THREADS", "4"), "-nt", "-np", "-otxt", *batch],
                       check=True, capture_output=True)  # fmt: skip
        print(f"  {min(k + 500, len(todo))}/{len(todo)}", flush=True)
    wall = time.monotonic() - t0
    # scale wall time to the whole set by audio duration, so RTF stays decode/audio
    if len(todo) < len(ids):
        done = sum(pcms[i].stat().st_size for i in todo) / sum(
            p.stat().st_size for p in pcms.values()
        )
        wall = wall / done if done else wall
    version = subprocess.run(
        ["whisper-cli", "--version"], capture_output=True, text=True
    ).stdout.strip()
    hyps = [{"id": i, "text": Path(f"{wavs[i]}.txt").read_text().strip()} for i in ids]
    return (
        hyps,
        f"whisper.cpp:large-v3-turbo ({version.splitlines()[-1]}, Metal, beam 5"
        + (
            f"; resumed, {len(todo)}/{len(ids)} segments timed, wall extrapolated by audio duration)"
            if len(todo) < len(ids)
            else ")"
        ),
        wall,
    )


def byte_decoder() -> dict[str, int]:
    """Inverse of GPT-2's bytes_to_unicode, which Whisper's byte-level BPE vocabulary uses."""
    bs = [*range(33, 127), *range(161, 173), *range(174, 256)]
    cs = bs + [256 + n for n in range(256 - len(bs))]
    return {chr(c): b for b, c in zip(bs + [b for b in range(256) if b not in bs], cs)}


def decode_ct2(pcms: dict[str, Path]) -> tuple[list[dict], str, float]:
    """Whisper large-v3-turbo through CTranslate2 (CPU, int8), the decoding faster-whisper's BatchedInferencePipeline
    does with clip_timestamps: one clip per segment, features padded to 30 s, beam 5, no timestamps, batch 16.
    ctranslate2 is called directly because the faster-whisper package imports PyAV (bundles LGPL FFmpeg) and tqdm
    (MPL-2.0), neither on LICENSES.md; only its MIT feature_extractor.py is loaded, by path (FW_FEATURES)."""
    import importlib.util

    import ctranslate2
    import numpy as np

    spec = importlib.util.spec_from_file_location("fw_features", os.environ["FW_FEATURES"])
    fw = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fw)
    fe = fw.FeatureExtractor(feature_size=128)
    vocab, bd = json.loads((CT2 / "vocabulary.json").read_text()), byte_decoder()
    eot = vocab.index("<|endoftext|>")
    threads = int(os.environ.get("WHISPER_THREADS", "4"))
    t0 = time.monotonic()
    model = ctranslate2.models.Whisper(
        str(CT2), device="cpu", compute_type="int8", intra_threads=threads
    )
    prompt = ["<|startoftranscript|>", "<|en|>", "<|transcribe|>", "<|notimestamps|>"]
    ids, hyps = list(pcms), []
    for k in range(0, len(ids), 16):
        feats = []
        for i in ids[k : k + 16]:
            x = np.frombuffer(pcms[i].read_bytes(), dtype=np.int16).astype(np.float32) / 32768
            f = fe(x[: 30 * 16_000])[..., :-1][..., :3000]
            feats.append(np.pad(f, ((0, 0), (0, 3000 - f.shape[-1]))))
        res = model.generate(ctranslate2.StorageView.from_array(np.stack(feats)), [prompt] * len(feats),
                             beam_size=5, max_length=448)  # fmt: skip
        for i, r in zip(ids[k : k + 16], res):
            b = bytearray(bd[c] for t in r.sequences_ids[0] if t < eot for c in vocab[t])
            hyps.append({"id": i, "text": b.decode("utf-8", "replace").strip()})
        if (
            k // 16
        ) % 25 == 0:  # first line shows a sample transcript, as a sanity check in the pod log
            print(
                f"  {len(hyps)}/{len(ids)}" + (f" e.g. {hyps[0]['text']!r}" if k == 0 else ""),
                flush=True,
            )
    wall = time.monotonic() - t0
    return (
        hyps,
        f"ctranslate2 {ctranslate2.__version__}:whisper-large-v3-turbo (CPU int8, beam 5, batch 16)",
        wall,
    )


SYSTEMS = {
    "zipformer": decode_zipformer,
    "whisper-large-v3-turbo": decode_whisper,
    "ct2-whisper-large-v3-turbo": decode_ct2,
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", choices=CORPORA, required=True)
    ap.add_argument("--system", choices=SYSTEMS, default="zipformer")
    ap.add_argument("--meeting", help="decode one meeting only (cluster shard)")
    ap.add_argument(
        "--from-shards",
        type=Path,
        help="score shard outputs <M>_<raw|norm>.{hyp.jsonl,summary.json}",
    )
    ap.add_argument("--limit", type=int, help="first N segments only (smoke test)")
    ap.add_argument("--rms-dbfs", type=float, help="normalise each segment to this RMS level (stand-in for the phone's"
                    " input gain; corpus far-field audio is far quieter than what the phone's ASR receives)")  # fmt: skip
    a = ap.parse_args()
    work = ROOT / ".build/corpus" / a.corpus
    (work / "pcm").mkdir(parents=True, exist_ok=True)
    refs, meeting = {}, {}
    for part in sorted(CORPORA[a.corpus].glob("*.parquet")):
        for row in pq.read_table(
            part, columns=["audio_id", "meeting_id", "text", "audio"]
        ).to_pylist():
            if a.limit and len(refs) >= a.limit:
                break
            if a.meeting and row["meeting_id"] != a.meeting:
                continue
            if not normalize(row["text"]):
                continue  # empty after normalisation (e.g. only noise tags): not scorable
            pcm = work / "pcm" / f"{row['audio_id']}.pcm"
            if not pcm.exists():
                pcm.write_bytes(pcm16_from_wav(row["audio"]["bytes"]))
            refs[row["audio_id"]], meeting[row["audio_id"]] = row["text"], row["meeting_id"]
    if not refs:
        print(f'no segments: run `make models ONLY="{a.corpus}-0000 …"` first')
        return 1
    print(f"{len(refs)} segments from {len(set(meeting.values()))} meetings; decoding…", flush=True)
    pcm_dir = "pcm"
    if (
        a.rms_dbfs is not None
    ):  # scaled copies, so raw and normalised runs share the extracted audio
        (work / "pcm_norm").mkdir(exist_ok=True)
        target = 32768 * 10 ** (a.rms_dbfs / 20)
        for i in refs:
            dst = work / "pcm_norm" / f"{i}.pcm"
            if not dst.exists():
                x = array.array("h", (work / "pcm" / f"{i}.pcm").read_bytes())
                rms = (sum(v * v for v in x) / max(1, len(x))) ** 0.5 or 1
                g = target / rms
                dst.write_bytes(
                    array.array("h", (max(-32768, min(32767, int(v * g))) for v in x)).tobytes()
                )
        pcm_dir = "pcm_norm"
    pcms = {i: work / pcm_dir / f"{i}.pcm" for i in refs}
    audio_s = sum(p.stat().st_size for p in pcms.values()) / 32_000
    level = "norm" if a.rms_dbfs is not None else "raw"
    if a.from_shards:
        shards = [
            json.loads(f.read_text()) for f in sorted(a.from_shards.glob(f"*_{level}.summary.json"))
        ]
        decoded = [
            json.loads(ln)
            for f in sorted(a.from_shards.glob(f"*_{level}.hyp.jsonl"))
            for ln in f.open()
        ]
        wall = sum(d["decode_wall_s"] for d in shards)
        system, cpu = (
            f"{shards[0]['system']}; {len(shards)} shards, CPU cluster",
            shards[0]["host"],
        )
    else:  # wall: decode seconds incl. model load, excl. audio prep
        (decoded, system, wall), cpu = SYSTEMS[a.system](pcms), host()
    hyps = {d["id"]: d["text"] for d in decoded}
    # zipformer keeps its original file names
    sys_tag = "" if a.system == "zipformer" else f"_{a.system}"
    (work / f"hyp{sys_tag}{'_norm' if a.rms_dbfs is not None else ''}.jsonl").write_text(
        "".join(json.dumps(d) + "\n" for d in decoded)
    )

    per = defaultdict(lambda: [0, 0])  # meeting → [edits, ref words]
    for i, ref in refs.items():
        r, h = normalize(ref), normalize(hyps.get(i, ""))
        per[meeting[i]][0] += edits(r, h)
        per[meeting[i]][1] += len(r)
    meetings = sorted(per)
    total = sum(per[m][0] for m in meetings) / sum(per[m][1] for m in meetings)
    rng, boots = random.Random(20261015), []
    for _ in range(2000):  # resample meetings, the unit of independence
        s = [per[rng.choice(meetings)] for _ in meetings]
        boots.append(sum(e for e, _ in s) / sum(n for _, n in s))
    boots.sort()
    summary = {
        "corpus": a.corpus, "segments": len(refs), "meetings": len(meetings), "ref_words": sum(per[m][1] for m in meetings),
        "wer": round(total, 4), "ci95": [round(boots[49], 4), round(boots[1949], 4)], "system": system,
        "audio_s": round(audio_s, 1), "decode_wall_s": round(wall, 1), "rtf": round(wall / audio_s, 4),
        "host": cpu,
        "segmentation": "oracle (corpus segments)", "normalisation": "tools/harness/wer.py normalize",
        "input_level": f"segment RMS normalised to {a.rms_dbfs} dBFS" if a.rms_dbfs is not None else "raw corpus level",
        "per_meeting": {m: round(per[m][0] / per[m][1], 4) for m in meetings}, "limit": a.limit,
    }  # fmt: skip
    tag = (
        sys_tag
        + (f"_{a.meeting}" if a.meeting else "")
        + ("_smoke" if a.limit else "")
        + (f"_rms{int(a.rms_dbfs)}" if a.rms_dbfs is not None else "_raw")
    )
    dest = ROOT / "docs/evidence/raw" / f"asr_{a.corpus}{tag}.json"
    dest.write_text(json.dumps(summary, indent=2) + "\n")
    print(
        f"{a.corpus}: WER {total:.1%} (95 % CI {boots[49]:.1%}–{boots[1949]:.1%}) over {len(meetings)} meetings, RTF {wall / audio_s:.3f} → {dest}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
