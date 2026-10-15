import asyncio
import json
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
import wer

from conftest import FIXTURES
from earbridge import asr, config, llm, tts

needs_models = pytest.mark.skipif(not config.EARCLI.exists() or not (config.MODELS / "silero-vad").exists(),
                                  reason="needs EarCLI release build and `make models`")  # fmt: skip


def pcm(name: str) -> bytes:
    with wave.open(str(FIXTURES / f"{name}.wav")) as w:
        assert (w.getframerate(), w.getnchannels()) == (16000, 1)
        return w.readframes(w.getnframes())


@needs_models
def test_ambient_asr_on_lecture_fixture():
    async def run():
        p = await asr.AsrProcess().start()
        data = pcm("lecture_en_01")
        for i in range(0, len(data), 32000):
            p.feed(data[i : i + 32000])
        await p.close()
        return [r async for r in p.results() if r["type"] == "final"]

    finals = asyncio.run(run())
    w = wer.wer(
        (FIXTURES / "scripts/lecture_en_01.txt").read_text(), " ".join(r["text"] for r in finals)
    )
    assert w <= 0.12, f"WER {w:.3f}"
    assert finals == sorted(finals, key=lambda r: r["t0"])


@needs_models
def test_utterance_mode_returns_the_question():
    async def run():
        p = await asr.AsrProcess(utterance=True).start()
        with wave.open(str(FIXTURES / "queries/lecture_en_01_q03.wav")) as w:
            p.feed(w.readframes(w.getnframes()))
        return await p.finish_utterance()

    assert asyncio.run(run()).lower().startswith("what did the speaker just say about the optimi")


@needs_models
def test_tts_first_chunk_within_400ms():
    async def run():
        sp = await tts.Speaker().start()
        await sp.synthesize("Warm up.")  # the worker stays warm per connection
        t0 = time.monotonic()
        first, total = None, 0
        async for chunk in sp.speak(
            "The deadline for the second assignment moves to Friday the fourteenth."
        ):
            first = first or time.monotonic() - t0
            total += len(chunk)
        sp.close()
        return first, total

    first, total = asyncio.run(run())
    assert first <= 0.4, f"first chunk {first:.3f} s"
    assert total > tts.SAMPLE_RATE * 2 * 1.0  # more than a second of 16-bit audio


class FakeOllama(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.end_headers()
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert self.path == "/api/chat" and body["think"] is False
        for word in ["The ", "deadline ", "moves ", "to ", "Friday.", "\nSOURCE: transcript"]:
            self.wfile.write(
                (json.dumps({"message": {"content": word}, "done": False}) + "\n").encode()
            )
            self.wfile.flush()
            time.sleep(0.02)
        self.wfile.write(b'{"message": {"content": ""}, "done": true}\n')

    def log_message(self, *a):
        pass


@pytest.fixture
def fake_ollama(monkeypatch):
    srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeOllama)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    monkeypatch.setattr(config, "OLLAMA", f"http://127.0.0.1:{srv.server_port}")
    yield
    srv.shutdown()


def test_llm_streams_in_order_and_cancels(fake_ollama):
    async def collect(cancel_after=None):
        ev, out = threading.Event(), []
        async for d in llm.stream_chat("sys", "user", model="m", cancel=ev):
            out.append(d)
            if cancel_after and len(out) == cancel_after:
                ev.set()
        return out

    assert "".join(asyncio.run(collect())) == "The deadline moves to Friday.\nSOURCE: transcript"
    assert len(asyncio.run(collect(cancel_after=2))) <= 3
