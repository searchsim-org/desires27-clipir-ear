"""Builds docs/evidence/latency.md from docs/evidence/raw/latency_*.json (P4.7, HANDOVER §9 and §15 A3).
Stage times are seconds after the end of the question (speechEnd), the user-perceived latency."""

import glob
import platform
import json
import statistics
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STAGES = [
    "earcon",
    "asrFinal",
    "contextReady",
    "llmFirstToken",
    "llmFirstSentence",
    "ttsFirstAudio",
    "audioOutStart",
    "done",
]
TARGETS = {
    "phone": {"earcon": 0.5, "audioOutStart": 2.5},
    "mac": {"earcon": 0.5, "audioOutStart": 1.5},
}
P95 = {"phone": 4.0, "mac": 2.5}


def pct(xs: list[float], p: float) -> float:
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p * (len(xs) - 1))))]


def main() -> int:
    rows = [
        r
        for f in sorted(glob.glob(str(ROOT / "docs/evidence/raw/latency_*.json")))
        for r in json.loads(Path(f).read_text())
    ]
    groups: dict[tuple[str, str, str], list[dict]] = {}
    for r in rows:
        groups.setdefault((r["device"], r["tier"], r.get("model", "")), []).append(r)
    lines = [
        "# Latency evidence (A3)",
        "",
        f"Built by `tools/harness/report.py` on {date.today()} from `docs/evidence/raw/latency_*.json`. Seconds after the end "
        "of the question (speechEnd). `audioOutStart` = first spoken audio queued to the output (≈ first word). "
        "Mac rows run the phone-tier pipeline on the Mac; they are not phone numbers (device runs: LoopBench, ADR-010).",
        "",
    ]
    for (device, tier, model), rs in sorted(groups.items()):
        lines += [
            f"## {device} — {tier} tier — {model} ({len(rs)} queries)",
            "",
            "| Stage | p50 | p95 | Target |",
            "|---|---|---|---|",
        ]
        for s in STAGES:
            xs = [r[s] - r["speechEnd"] for r in rs if s in r and "speechEnd" in r]
            if not xs:
                continue
            target = TARGETS[tier].get(s)
            t = (
                f"p50 ≤ {target} s" + (f", p95 ≤ {P95[tier]} s" if s == "audioOutStart" else "")
                if target
                else ""
            )
            lines.append(f"| {s} | {statistics.median(xs):.2f} s | {pct(xs, 0.95):.2f} s | {t} |")
        mem = [r["memory_footprint_mb"] for r in rs if r.get("memory_footprint_mb")]
        thermal = sorted({r.get("thermal_state", "?") for r in rs})
        lines += (
            [
                "",
                f"Peak footprint {max(mem):.0f} MB; thermal states seen: {', '.join(thermal)}.",
                "",
            ]
            if mem
            else [""]
        )
    (ROOT / "docs/evidence/latency.md").write_text("\n".join(lines))
    print(f"wrote docs/evidence/latency.md ({len(rows)} queries)")
    egress()
    soak_and_stability()
    readme()
    return 0


def egress() -> None:
    """docs/evidence/egress.md (A6): static scan + the EgressGuard ledger of every harness run."""
    import subprocess

    static = subprocess.run(
        [sys.executable, str(ROOT / "tools/ci/egress_check.py"), str(ROOT)],
        capture_output=True,
        text=True,
    )
    lines = ["# Egress evidence (A6)", "", f"Built by `tools/harness/report.py` on {date.today()}.", "",
             "## Static scan (`tools/ci/egress_check.py`)", "", "```", static.stdout.strip(), "```", "",
             "## Runtime ledger (EgressGuard / ConnectionLedger) during full scenario runs", "",
             "| Run | Questions | Destinations | Outside allow-list |", "|---|---|---|---|"]  # fmt: skip
    for f in sorted(glob.glob(str(ROOT / "docs/evidence/raw/egress_*.json"))):
        e = json.loads(Path(f).read_text())
        hosts = sorted({x["host"] for x in e["ledger"]})
        bad = [x["host"] for x in e["ledger"] if not x["allowed"]]
        dest = ", ".join(hosts) or "none (no network use)"
        lines.append(f"| {e['tier']} tier, {e['fixture']} | {e['queries']} | {dest} | {len(bad)} |")
    lines += ["", "Phone tier: the pipeline opens no connection at all. Mac tier: the only destination is the paired Mac "
              "(here `127.0.0.1`, because the harness runs earbridge locally)."]  # fmt: skip
    (ROOT / "docs/evidence/egress.md").write_text("\n".join(lines) + "\n")
    print("wrote docs/evidence/egress.md")


def soak_and_stability() -> None:
    raw = ROOT / "docs/evidence/raw"
    if (f := raw / "soak_EarSim.json").exists():
        d = json.loads(f.read_text())
        rows = d["samples"]
        lines = ["# Ambient soak (A4/A5) — EarSim", "",
                 f"{d['minutes']:.0f} minutes of lecture fixtures back to back in real time through the full ambient pipeline "
                 "(Silero + Zipformer + store + retention + embeddings) on the iPhone 13 Pro Max simulator. Simulator: no "
                 "battery, CPU of the Mac — this shows stability and memory trend only; device soak pending (ADR-010).", "",
                 f"- Frames delivered: {d['frames']} of {d['expected_frames']} expected "
                 f"({100 * d['frames'] / d['expected_frames']:.2f} %; target dropped < 1 %)",
                 f"- Peak footprint: {max(r['footprint_mb'] for r in rows):.0f} MB (target ≤ 3,584 MB)",
                 f"- Thermal states: {', '.join(sorted({r['thermal'] for r in rows}))}",
                 f"- Segments stored at the end: {rows[-1]['segments']}", "",
                 "| Minute | Footprint MB | Thermal | Segments |", "|---|---|---|---|"]  # fmt: skip
        lines += [
            f"| {r['minute']} | {r['footprint_mb']:.0f} | {r['thermal']} | {r['segments']} |"
            for r in rows
        ]
        (ROOT / "docs/evidence/soak.md").write_text("\n".join(lines) + "\n")
        print("wrote docs/evidence/soak.md")
    if (f := raw / "stability_EarSim.json").exists():
        d = json.loads(f.read_text())
        fp = [r["footprint_mb"] for r in d["runs"]]
        lines = ["# Demo stability (A7) — EarSim", "",
                 "The demo scenario (ambient lecture, two recorded questions, a spoken reminder approved with \"yes\", "
                 "\"forget the last ten minutes\", export) ten times in one process on the simulator "
                 "(`make stability`). Device version: a device check.", "",
                 f"- Runs completed: {len(d['runs'])} of 10; test {'passed' if d['passed'] else 'FAILED'}",
                 f"- Footprint per run (MB): {fp}"]  # fmt: skip
        (ROOT / "docs/evidence/stability.md").write_text("\n".join(lines) + "\n")
        print("wrote docs/evidence/stability.md")


def readme() -> None:
    """docs/evidence/README.md (P7.2): everything needed to cite these numbers."""
    import subprocess

    def run(*cmd):
        return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()

    lock = json.loads((ROOT / "tools/models/models.lock.json").read_text())["models"]
    xcode = run("xcodebuild", "-version").replace("\n", " ")
    lines = [
        "# Evidence pack (v0.1)", "",
        f"- Generated: {date.today()} by `make report`",
        f"- Build: git `{run('git', '-C', str(ROOT), 'rev-parse', '--short', 'HEAD')}` "
        f"({run('git', '-C', str(ROOT), 'describe', '--tags', '--always')})",
        f"- Machine: {run('sysctl', '-n', 'hw.model')}, {run('sysctl', '-n', 'machdep.cpu.brand_string')}, "
        f"{int(run('sysctl', '-n', 'hw.memsize')) // 2**30} GB",
        f"- macOS {platform.mac_ver()[0]}; {xcode}; simulator EarSim = iPhone 13 Pro Max, iOS 18.3.1",
        "- Phone-tier numbers come from the phone pipeline running on this Mac (Metal) or on EarSim (CPU). They are not "
        "iPhone numbers: device runs (LLMBench, LoopBench, AmbientSoak on the iPhone) are pending a signed build (ADR-010).",
        "", "## Files", "",
        "| File | Content | Targets |", "|---|---|---|",
        "| asr.md | WER per fixture × noise variant + LibriSpeech sample | A1 |",
        "| qa.md | grounded QA accuracy per fixture × model | A2 |",
        "| latency.md | stage latency p50/p95 per tier | A3 |",
        "| soak.md | 30-min ambient soak (EarSim) | A4, A5 (simulator only) |",
        "| egress.md | static scan + runtime ledger of full scenario runs | A6 |",
        "| stability.md | demo scenario ×10 (EarSim) | A7 (simulator only; device = a device check) |",
        "| raw/*.json | every measurement behind the tables | |",
        "", "## Models (tools/models/models.lock.json)", "", "| Model | File | SHA-256 | Licence |", "|---|---|---|---|",
    ]  # fmt: skip
    lines += [
        f"| {m['id']} | `{m['file']}` | `{m['sha256'][:16]}…` | {m['licence']} |" for m in lock
    ]
    lines += ["", "Runtime pins: sherpa-onnx v1.13.8 (TTS off), llama.cpp b11624, GRDB 7.8.0, onnxruntime 1.28.2, "
              "Ollama 0.34.2 serving `clipir-gemma4-e2b` (Mac tier, ADR-017).", "",
              "## Not measured yet (needs the iPhone)", "",
              "LLMBench (TTFT, tok/s), LoopBench (device latency), AmbientSoak on the device (battery %/h, thermal, "
              "jetsam), the device checks."]  # fmt: skip
    (ROOT / "docs/evidence/README.md").write_text("\n".join(lines) + "\n")
    print("wrote docs/evidence/README.md")


if __name__ == "__main__":
    sys.exit(main())
