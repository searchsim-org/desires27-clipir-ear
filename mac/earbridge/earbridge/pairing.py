"""Pairing (HANDOVER §7, P5.4): an 8-character code that is also the token, shown as text and as a QR code."""

import json
import secrets
import socket
import subprocess

from . import config, tls

ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O/1/I


def new_token() -> str:
    return "".join(
        secrets.choice(ALPHABET) for _ in range(8)
    )  # ≈ 40 bits; hello is rate-limited (server.py)


def lan_ips() -> list[str]:
    ips = []
    for iface in ("en0", "en1", "utun4"):
        r = subprocess.run(["ipconfig", "getifaddr", iface], capture_output=True, text=True)
        if r.stdout.strip():
            ips.append(r.stdout.strip())
    return ips or ["127.0.0.1"]


def pair(host: str | None = None) -> dict:
    cfg = config.load()
    cfg["token"] = new_token()
    config.save(cfg)
    payload = {
        "host": host or lan_ips()[0],
        "port": config.PORT,
        "token": cfg["token"],
        "fp": tls.fingerprint(),  # P8.4: the phone pins this certificate
    }
    return payload


def print_qr(payload: dict) -> None:
    import qrcode

    qr = qrcode.QRCode(border=1)
    qr.add_data(json.dumps(payload, separators=(",", ":")))
    qr.print_ascii(invert=True)
    print(f"\n  Short code: {payload['token']}   (host {payload['host']}:{payload['port']})")
    print(f"  QR payload: {json.dumps(payload, separators=(',', ':'))}")


def hostname() -> str:
    return socket.gethostname().split(".")[0]
