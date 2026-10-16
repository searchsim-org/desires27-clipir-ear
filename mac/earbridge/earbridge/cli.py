"""earbridge serve | pair | status | doctor [--fix] (P5.1, P5.3)."""

import argparse
import asyncio
import importlib.util
import json
import ssl
import socket
import subprocess
import sys
import tempfile
import threading
import urllib.request
from pathlib import Path

from . import config, llm, pairing, server, wizard
from .store import Store


def tailscale_ip() -> str | None:
    out = subprocess.run(["ifconfig"], capture_output=True, text=True).stdout
    return next(
        (ln.split()[1] for ln in out.splitlines() if ln.strip().startswith("inet 100.")), None
    )


def cmd_serve(a) -> int:
    token = a.token or config.load().get("token")
    if not token:
        print("not paired yet: run `earbridge pair` first", file=sys.stderr)
        return 1
    host = a.host
    if a.tailscale_only:
        host = tailscale_ip() or sys.exit("no Tailscale (100.x) address found")

    def warm():  # load the model in the background so the first answer is not a cold start (§17)
        try:
            llm.warm(a.model)
        except Exception as e:
            print(f"warning: could not warm {a.model}: {e}", file=sys.stderr)

    threading.Thread(target=warm, daemon=True).start()
    store = Store(a.db or config.DB_PATH)
    asyncio.run(
        server.run(
            host,
            a.port,
            token,
            a.model,
            store,
            advertise=not a.no_bonjour,
            use_tls=not a.no_tls,
            desk=wizard.Desk(a.wizard_delay, wizard.load_bank(a.wizard_bank)) if a.wizard else None,
        )
    )
    return 0


def cmd_pair(a) -> int:
    payload = pairing.pair(a.host)
    pairing.print_qr(payload)
    return 0


def cmd_status(_a) -> int:
    try:
        ctx = ssl._create_unverified_context()  # our own self-signed cert on localhost
        with urllib.request.urlopen(
            f"https://127.0.0.1:{config.PORT}/health", timeout=2, context=ctx
        ) as r:
            print("earbridge running:", json.load(r))
    except Exception:
        print("earbridge not running")
    print("paired:", "yes" if config.load().get("token") else "no")
    return 0


def ensure_model(model: str) -> bool:
    """Imports the pinned GGUF into Ollama as `model` (ADR-015: never `ollama pull`)."""
    gguf = config.LLM_GGUFS.get(model)
    if gguf is None or not gguf.exists():
        print(
            f"  no pinned GGUF for {model} (known: {', '.join(config.LLM_GGUFS)}); run `make models`"
        )
        return False
    with tempfile.NamedTemporaryFile("w", suffix=".Modelfile", delete=False) as f:
        f.write(f"FROM {gguf}\nPARAMETER temperature 0\nPARAMETER num_ctx 8192\n")
    return subprocess.run(["ollama", "create", model, "-f", f.name]).returncode == 0


def cmd_doctor(a) -> int:
    ok = True

    def check(name: str, good: bool, detail: str = "") -> None:
        nonlocal ok
        ok &= good
        print(f"  {'ok  ' if good else 'FAIL'} {name:18} {detail}")

    try:
        names = llm.models()
        check("ollama", True, config.OLLAMA)
        have = any(n.split(":")[0] == a.model for n in names)
        if not have and a.fix:
            have = ensure_model(a.model)
        check("llm model", have, a.model if have else f"{a.model} missing (earbridge doctor --fix)")
    except Exception as e:
        check("ollama", False, f"not reachable: {e}")
    check(
        "EarCLI",
        config.EARCLI.exists(),
        str(config.EARCLI) if config.EARCLI.exists() else "swift build -c release --product EarCLI",
    )
    for f in ("silero-vad/silero_vad_v5.onnx", "zipformer-en-2023-06-26/tokens.txt"):
        check("model " + f.split("/")[0], (config.MODELS / f).exists(), f)
    s = socket.socket()
    port_free = s.connect_ex(("127.0.0.1", config.PORT)) != 0
    s.close()
    check("port", True, f"{config.PORT} {'free' if port_free else 'in use (earbridge running?)'}")
    check("say (TTS)", Path("/usr/bin/say").exists(), "/usr/bin/say")
    check("dns-sd (Bonjour)", Path("/usr/bin/dns-sd").exists(), "_clipir-ear._tcp")
    print(f"  LAN addresses: {', '.join(pairing.lan_ips())}   Tailscale: {tailscale_ip() or '—'}")
    print("doctor:", "OK" if ok else "FAILED")
    return 0 if ok else 1


def cmd_export(a) -> int:
    from . import export

    store = Store(a.db or config.DB_PATH)
    if getattr(a, "clipir", None):
        from . import clipir

        n = clipir.to_clipir(
            store,
            a.session,
            a.clipir,
            include_qa=a.include_qa,
            include_transcript=a.include_transcript,
        )
        print(f"wrote {n} rows to {a.clipir}")
    else:
        print(
            json.dumps(
                export.measures(store, a.session, a.include_qa, a.include_transcript), indent=2
            )
        )
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="earbridge")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--host", default="0.0.0.0")
    s.add_argument("--port", type=int, default=config.PORT)
    s.add_argument("--model", default=config.LLM_MODEL)
    s.add_argument("--tailscale-only", action="store_true")
    s.add_argument("--no-bonjour", action="store_true")
    s.add_argument(
        "--no-tls", action="store_true", help="plain ws:// (tests; pairing QR then needs fp=none)"
    )
    s.add_argument(
        "--wizard", action="store_true", help="Wizard of Oz: a person answers at /wizard (research)"
    )
    s.add_argument(
        "--wizard-delay",
        type=float,
        default=0.0,
        help="earliest answer, seconds after the question",
    )
    s.add_argument("--wizard-bank", help="JSON list of prepared answers shown on the console")
    s.add_argument("--token", help="override the paired token (tests)")
    s.add_argument("--db", help="database path (tests; default the Mac mirror ear.db)")
    s.set_defaults(fn=cmd_serve)
    p = sub.add_parser("pair")
    p.add_argument("--host")
    p.set_defaults(fn=cmd_pair)
    sub.add_parser("status").set_defaults(fn=cmd_status)
    d = sub.add_parser("doctor")
    d.add_argument("--model", default=config.LLM_MODEL)
    d.add_argument("--fix", action="store_true", help="import the pinned GGUF into Ollama")
    d.set_defaults(fn=cmd_doctor)
    e = sub.add_parser("export", help="session measures as JSON")
    e.add_argument("--session", required=True)
    if importlib.util.find_spec(
        "earbridge.clipir"
    ):  # private adapter, left out of the public release
        e.add_argument("--clipir", help="path to a ClipIR events.db")
    e.add_argument("--include-qa", action="store_true")
    e.add_argument("--include-transcript", action="store_true")
    e.add_argument("--db")
    e.set_defaults(fn=cmd_export)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
