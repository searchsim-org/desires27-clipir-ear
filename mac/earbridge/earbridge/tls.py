"""Self-signed TLS for the bridge (P8.4). The cert is made once with the macOS openssl CLI; the phone pins
its SHA-256 (from the pairing QR), so no CA is involved."""

import hashlib
import ssl
import subprocess

from . import config

CERT, KEY = config.SUPPORT / "earbridge.crt", config.SUPPORT / "earbridge.key"


def ensure() -> None:
    if CERT.exists() and KEY.exists():
        return
    config.SUPPORT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
                    "-subj", "/CN=earbridge", "-keyout", str(KEY), "-out", str(CERT)],
                   check=True, capture_output=True)  # fmt: skip
    KEY.chmod(0o600)


def fingerprint() -> str:
    """Lower-case hex SHA-256 of the DER certificate; what the QR's `fp` and Bonjour's TXT `fp` carry."""
    ensure()
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(CERT.read_text())).hexdigest()


def context() -> ssl.SSLContext:
    ensure()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT, KEY)
    return ctx
