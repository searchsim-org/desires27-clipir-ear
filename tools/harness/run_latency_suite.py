"""Latency suite (P4.7, macOS part): EarCLI loop plays a fixture in real time through the full pipeline (Silero +
Zipformer + LLM + SystemSpeaker into a silent real-time output) and asks each recorded question 5 s after its fact.
Raw traces → docs/evidence/raw/latency_<device>_<tier>.json; then run report.py. Device runs use ClipIREarTests/LoopBench.
Usage: run_latency_suite.py [--fixture lecture_en_01] [--model llm/gemma-4-E2B-it-Q4_0.gguf] [--tier phone|mac]
--tier mac starts a throwaway `earbridge serve` and runs the same device-side pipeline against it (Mac tier).
Each run also saves the EgressGuard ledger (docs/evidence/raw/egress_<tier>.json) for report.py → egress.md.
"""

import argparse
import json
import platform
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixture", default="lecture_en_01")
    ap.add_argument("--model", default="llm/gemma-4-E2B-it-Q4_0.gguf")
    ap.add_argument("--tier", choices=["phone", "mac"], default="phone")
    a = ap.parse_args(argv)
    subprocess.run(["swift", "build", "-c", "release", "--product", "EarCLI"], cwd=ROOT, check=True)
    bin_dir = subprocess.run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=ROOT, check=True,
                             capture_output=True, text=True).stdout.strip()  # fmt: skip
    fix = ROOT / "Tests/Fixtures"
    cmd = [f"{bin_dir}/EarCLI", "loop", "--wav", str(fix / f"{a.fixture}.wav"), "--queries", str(fix / "queries/en.json"),
           "--model", a.model]  # fmt: skip
    server = None
    if a.tier == "mac":
        server = subprocess.Popen(
            ["uv", "run", "--project", str(ROOT / "mac/earbridge"), "earbridge", "serve", "--host", "127.0.0.1", "--port",
             "9481", "--token", "HARNESS1", "--no-bonjour", "--no-tls", "--db", ":memory:"],
            stderr=subprocess.DEVNULL,
        )  # fmt: skip
        for _ in range(100):
            try:
                urllib.request.urlopen("http://127.0.0.1:9481/health", timeout=1)
                break
            except OSError:
                time.sleep(0.2)
        time.sleep(3)  # let earbridge warm its model
        cmd += ["--mac", "127.0.0.1:9481:HARNESS1"]
    try:
        out = subprocess.run(cmd, cwd=ROOT, check=True, capture_output=True, text=True).stdout
    finally:
        if server:
            server.terminate()
    lines = [json.loads(line) for line in out.splitlines() if line.startswith("{")]
    ledger = next((x["ledger"] for x in lines if "ledger" in x), [])
    rows = [x for x in lines if "ledger" not in x]
    device = "mac-" + platform.machine() + (" → earbridge (localhost)" if a.tier == "mac" else "")
    for r in rows:
        r["device"], r["tier"] = device, a.tier  # the device-side pipeline, running on the Mac
    raw_dir = ROOT / "docs/evidence/raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    egress = {"tier": a.tier, "fixture": a.fixture, "queries": len(rows), "ledger": ledger}
    (raw_dir / f"egress_{a.tier}_{a.fixture}.json").write_text(json.dumps(egress, indent=2) + "\n")
    raw = raw_dir / f"latency_{platform.machine()}_{a.tier}_{a.fixture}.json"
    raw.parent.mkdir(parents=True, exist_ok=True)
    raw.write_text(json.dumps(rows, indent=2) + "\n")
    print(f"{len(rows)} queries → {raw.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
