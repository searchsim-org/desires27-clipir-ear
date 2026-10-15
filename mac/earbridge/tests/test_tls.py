"""P8.4: the server presents the certificate whose SHA-256 the pairing QR carries."""

import asyncio
import contextlib
import hashlib
import ssl

from websockets.asyncio.client import connect

from earbridge import config, pairing, protocol, server, tls
from earbridge.store import Store


def test_tls_fingerprint_matches_pairing(monkeypatch, port=9571):
    monkeypatch.setattr(config, "save", lambda cfg: None)  # do not rotate the owner's token
    assert pairing.pair("127.0.0.1")["fp"] == tls.fingerprint()

    async def run():
        ready = asyncio.Event()
        task = asyncio.create_task(server.run("127.0.0.1", port, "GOODTOKN", config.LLM_MODEL, Store(),
                                              advertise=False, ready=ready, use_tls=True))  # fmt: skip
        await ready.wait()
        ctx = ssl.create_default_context()
        ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE  # pinning, not CA trust
        try:
            async with connect(f"wss://127.0.0.1:{port}/ear/v1", ssl=ctx) as ws:
                der = ws.transport.get_extra_info("ssl_object").getpeercert(binary_form=True)
                await ws.send(protocol.encode("ping", ts=1.0))
                return der
        finally:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task

    assert hashlib.sha256(asyncio.run(run())).hexdigest() == tls.fingerprint()
