"""Extract the LibriSpeech test-clean sample (HANDOVER P0.7). Run via: make fixtures

Reads the pinned parquet downloaded by `make models ONLY=librispeech-test-clean` (sources.json, ADR-006)
and writes librispeech_sample/<id>.wav (16 kHz mono 16-bit, not committed) + refs.json (committed).
Selection: the first utterance (by id) of each of the first 20 speakers (by speaker id) — 20 voices.
LibriSpeech: Panayotov et al., ICASSP 2015, CC BY 4.0 (OpenSLR resource SLR12).
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parent
PARQUET = (
    Path.home() / "Library/Application Support/ClipIREar/models/librispeech-test-clean/0000.parquet"
)
OUT = ROOT / "librispeech_sample"
N_SPEAKERS = 20


def select(rows: list[dict]) -> list[dict]:
    first = {}
    for r in sorted(rows, key=lambda r: r["id"]):
        first.setdefault(r["speaker_id"], r)
    return [first[s] for s in sorted(first)[:N_SPEAKERS]]


def main() -> int:
    if not PARQUET.exists():
        print("missing LibriSpeech parquet: run `make models ONLY=librispeech-test-clean`")
        return 1
    meta = pq.read_table(PARQUET, columns=["id", "speaker_id", "text"]).to_pylist()
    chosen = {r["id"] for r in select(meta)}
    table = pq.read_table(PARQUET, columns=["id", "audio"], filters=[("id", "in", chosen)])
    audio = {r["id"]: r["audio"]["bytes"] for r in table.to_pylist()}
    OUT.mkdir(exist_ok=True)
    refs = []
    with tempfile.TemporaryDirectory() as tmp:
        for r in select(meta):
            flac, wav = Path(tmp) / f"{r['id']}.flac", OUT / f"{r['id']}.wav"
            flac.write_bytes(audio[r["id"]])
            subprocess.run(
                ["sox", "-R", "-D", str(flac), "-r", "16000", "-c", "1", "-b", "16", str(wav)],
                check=True,
            )
            refs.append(
                {"id": r["id"], "speaker_id": r["speaker_id"], "text": r["text"], "wav": wav.name}
            )
    (OUT / "refs.json").write_text(json.dumps(refs, indent=2) + "\n")
    print(
        f"librispeech: {len(refs)} utterances from {len({r['speaker_id'] for r in refs})} speakers"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
