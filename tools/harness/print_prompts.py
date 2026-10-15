"""Print a fixture's planted-fact timestamps and questions (for a device check). Usage: print_prompts.py lecture_en_01"""

import json
import sys
from pathlib import Path

FIX = Path(__file__).resolve().parents[2] / "Tests/Fixtures"


def main(argv: list[str]) -> int:
    name = argv[0] if argv else "lecture_en_01"
    for i, f in enumerate(json.loads((FIX / f"{name}.facts.json").read_text()), 1):
        m, s = divmod(int(f["t"]), 60)
        print(
            f"{i:2}. at {m}:{s:02d} (+5 s) — ask: {f['question']}   [expect: {' / '.join(f['must_contain'])}]"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
