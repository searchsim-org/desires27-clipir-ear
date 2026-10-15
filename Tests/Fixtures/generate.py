"""Generate deterministic audio fixtures (HANDOVER P0.7, English only per ADR-004). Run: make fixtures

Inputs:  Tests/Fixtures/scripts/<name>.src   lines "SPEAKER: text [## fact=… ## q=… ## must=a|b]"
Outputs (WAVs are not committed; regenerate with make fixtures):
  <name>.wav, <name>_snr20.wav, <name>_snr10.wav   16 kHz mono 16-bit, café-like noise mix
  scripts/<name>.txt         clean text, one utterance per line (a device check reading script, WER reference)
  <name>.facts.json          [{"t", "fact", "question", "must_contain", "speaker"}]; t = end of the fact utterance (s)
  <name>.timeline.json       [{"t0", "t1", "speaker", "text"}] per utterance
  queries/<name>_qNN.wav + queries/en.json   questions spoken by QUERY_VOICE
  SHA256SUMS                 hashes of every generated file (determinism check: run twice, no diff)
"""

import array
import hashlib
import json
import math
import re
import subprocess
import sys
import wave
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / ".build"
RATE_WPM = 175  # fixed so system speech settings do not change the output
SR = 16_000
LEAD, GAP, TURN_GAP, TAIL = 0.5, 0.6, 1.0, 1.0  # seconds of silence
QUERY_VOICE = "Moira"  # never used inside a fixture
SNRS = (20, 10)


def parse(src: Path):
    voices, lines = {}, []
    for raw in src.read_text().splitlines():
        if raw.startswith("# voices:"):
            voices = dict(kv.split("=") for kv in raw.split(":", 1)[1].split())
        elif raw.strip() and not raw.startswith("#"):
            spk, rest = raw.split(":", 1)
            parts = [p.strip() for p in rest.split("##")]
            fact = dict(p.split("=", 1) for p in parts[1:]) or None
            lines.append((spk.strip(), parts[0], fact))
    return voices, lines


def say(voice: str, text: str) -> Path:
    key = hashlib.sha256(f"{voice}|{RATE_WPM}|{text}".encode()).hexdigest()[:16]
    out = BUILD / f"{key}.wav"
    if not out.exists():
        tmp = out.with_suffix(".tmp.wav")
        subprocess.run(
            ["say", "-v", voice, "-r", str(RATE_WPM), "-o", str(tmp),
             "--file-format=WAVE", f"--data-format=LEI16@{SR}", text],
            check=True,
        )  # fmt: skip
        tmp.replace(out)
    return out


def read_pcm(path: Path) -> array.array:
    with wave.open(str(path)) as w:
        assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (SR, 1, 2), path
        return array.array("h", w.readframes(w.getnframes()))


def write_wav(path: Path, pcm: array.array) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def silence(sec: float) -> array.array:
    return array.array("h", bytes(2 * round(sec * SR)))


def rms(pcm, spans=None) -> float:
    spans = spans or [(0, len(pcm))]
    n = sum(b - a for a, b in spans)
    return math.sqrt(sum(pcm[i] * pcm[i] for a, b in spans for i in range(a, b)) / n)


def noise(seconds: float) -> array.array:
    # ponytail: brown noise + low-pass stands in for café noise (HANDOVER P0.7); -R makes sox's RNG repeatable
    out = BUILD / f"noise_{seconds:.3f}.wav"
    if not out.exists():
        subprocess.run(
            ["sox", "-R", "-D", "-n", "-r", str(SR), "-c", "1", "-b", "16", str(out),
             "synth", f"{seconds:.3f}", "brownnoise", "lowpass", "1200", "norm", "-6"],
            check=True,
        )  # fmt: skip
    return read_pcm(out)


def mix(clean: array.array, spans, snr_db: float) -> array.array:
    n = noise(len(clean) / SR)[: len(clean)]
    k = rms(clean, spans) / (rms(n) * 10 ** (snr_db / 20))
    return array.array("h", (max(-32768, min(32767, round(c + k * x))) for c, x in zip(clean, n)))


def build_fixture(name: str, pool: ThreadPoolExecutor) -> list[dict]:
    voices, lines = parse(ROOT / "scripts" / f"{name}.src")
    clips = list(pool.map(lambda ln: say(voices[ln[0]], ln[1]), lines))
    pcm, timeline, facts, spans, prev = silence(LEAD), [], [], [], None
    for (spk, text, fact), clip in zip(lines, clips):
        if prev is not None:
            pcm += silence(TURN_GAP if spk != prev else GAP)
        start, seg = len(pcm), read_pcm(clip)
        pcm += seg
        spans.append((start, len(pcm)))
        t0, t1 = round(start / SR, 3), round(len(pcm) / SR, 3)
        timeline.append({"t0": t0, "t1": t1, "speaker": voices[spk], "text": text})
        if fact:
            facts.append({
                "t": t1, "fact": fact["fact"], "question": fact["q"],
                "must_contain": fact["must"].split("|"), "speaker": voices[spk],
            })  # fmt: skip
        prev = spk
    pcm += silence(TAIL)
    write_wav(ROOT / f"{name}.wav", pcm)
    for snr in SNRS:
        write_wav(ROOT / f"{name}_snr{snr}.wav", mix(pcm, spans, snr))
    (ROOT / "scripts" / f"{name}.txt").write_text("\n".join(t for _, t, _ in lines) + "\n")
    (ROOT / f"{name}.facts.json").write_text(json.dumps(facts, indent=2) + "\n")
    (ROOT / f"{name}.timeline.json").write_text(json.dumps(timeline, indent=2) + "\n")
    queries = []
    for i, f in enumerate(facts, 1):
        wav = ROOT / "queries" / f"{name}_q{i:02d}.wav"
        write_wav(wav, read_pcm(say(QUERY_VOICE, f["question"])))
        queries.append({"fixture": name, "t": f["t"], "question": f["question"], "wav": wav.name})
    print(f"  {name}: {len(pcm) / SR:.1f} s, {len(lines)} utterances, {len(facts)} facts")
    return queries


def main() -> int:
    names = sorted(p.stem for p in (ROOT / "scripts").glob("*.src"))
    BUILD.mkdir(exist_ok=True)
    (ROOT / "queries").mkdir(exist_ok=True)
    with ThreadPoolExecutor(8) as pool:
        queries = [q for n in names for q in build_fixture(n, pool)]
    (ROOT / "queries" / "en.json").write_text(json.dumps(queries, indent=2) + "\n")
    outputs = sorted(
        p for p in ROOT.rglob("*")
        if p.is_file() and not {".build", "librispeech_sample"} & set(p.parts) and re.search(r"\.(wav|json|txt)$", p.name)
    )  # fmt: skip
    sums = [f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(ROOT)}" for p in outputs]
    (ROOT / "SHA256SUMS").write_text("\n".join(sums) + "\n")
    print(f"fixtures: {len(names)} scripts, {len(queries)} queries, {len(outputs)} files hashed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
