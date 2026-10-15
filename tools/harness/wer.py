"""Word error rate (P2.9). Same normalisation as Tests/EarCoreTests/Fixtures.swift (WER):
lower case, apostrophes dropped, letters/digits only, numbers 0–20 and tens spelled out.

Usage: python3 tools/harness/wer.py --ref <script.txt> --hyp <transcript.txt|.jsonl>
(.jsonl: one segment per line with a "text" field, as written by EarCLI transcribe or the app's debug export)
"""

import argparse
import json
import re
import sys
from pathlib import Path

# ponytail: a 15-line edit distance instead of jiwer; same result for WER, no dependency.
NUMBERS = dict(
    zip(
        [str(i) for i in range(21)] + ["30", "40", "50", "60", "70", "80", "90"],
        "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen "
        "sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety".split(),
    )
)


def normalize(text: str) -> list[str]:
    words = re.findall(r"[^\W_]+", text.lower().replace("'", "").replace("’", ""))
    return [NUMBERS.get(w, w) for w in words]


def wer(reference: str, hypothesis: str) -> float:
    r, h = normalize(reference), normalize(hypothesis)
    if not r:
        return 0.0 if not h else 1.0
    prev = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        cur = [i] + [0] * len(h)
        for j, hw in enumerate(h, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (rw != hw))
        prev = cur
    return prev[-1] / len(r)


def read_text(path: Path) -> str:
    raw = path.read_text()
    if path.suffix == ".jsonl":
        return " ".join(json.loads(line)["text"] for line in raw.splitlines() if line.strip())
    return raw


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ref", required=True, type=Path)
    ap.add_argument("--hyp", required=True, type=Path)
    a = ap.parse_args(argv)
    print(f"WER {wer(read_text(a.ref), read_text(a.hyp)) * 100:.1f} %")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
