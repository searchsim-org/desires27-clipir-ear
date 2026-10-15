import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "tools/harness"))  # wer.py
FIXTURES = REPO / "Tests/Fixtures"
