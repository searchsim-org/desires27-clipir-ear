"""End-to-end over a real WebSocket (P5 tests). Fast variant: scripted LLM. Real variant (EARBRIDGE_E2E_REAL=1):
the configured Ollama model; asserts ≥ 9/10 QA on lecture_en_01 and answer.done latency p50 ≤ 1.5 s."""

import asyncio
import json
import os
import statistics
import wave

import pytest
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

from conftest import FIXTURES
from earbridge import config, llm, protocol, server
from earbridge.store import Store

needs_models = pytest.mark.skipif(
    not config.EARCLI.exists(), reason="needs EarCLI release build and models"
)
REAL = os.environ.get("EARBRIDGE_E2E_REAL") == "1"


async def scripted(system, user, **_):
    q = user.rsplit("QUESTION:", 1)[-1].strip().lower()
    for w in f"You asked about {q.split('about')[-1].strip(' ?')} today.\nSOURCE: transcript".split(
        " "
    ):
        yield w + " "


async def start_server(port_holder: dict):
    ready = asyncio.Event()
    task = asyncio.create_task(server.run("127.0.0.1", port_holder["port"], "GOODTOKN", config.LLM_MODEL, Store(),
                                          advertise=False, ready=ready))  # fmt: skip
    await ready.wait()
    return task


def wav_pcm(path) -> bytes:
    with wave.open(str(path)) as w:
        return w.readframes(w.getnframes())


async def ask(ws, qid: str, wav, at: float | None = None):
    await ws.send(protocol.encode("query.begin", query_id=qid, session_id="s1"))
    pcm = wav_pcm(wav)
    t0 = asyncio.get_running_loop().time()
    for i in range(
        0, len(pcm), 640
    ):  # 20 ms frames at real-time pace, as push-to-talk streams them
        await ws.send(protocol.binary(protocol.KIND_PCM_IN, i // 640, pcm[i : i + 640]))
        await asyncio.sleep(max(0, t0 + (i + 640) / 32000 - asyncio.get_running_loop().time()))
    fields = {"at": at} if at is not None else {}
    await ws.send(protocol.encode("query.end", query_id=qid, window_seconds=60, **fields))
    answer, audio, done = "", 0, None
    while done is None:
        msg = await ws.recv()
        if isinstance(msg, bytes):
            audio += len(protocol.parse_binary(msg)[2])
            continue
        m = json.loads(msg)
        if m["t"] == "answer.token" and m["query_id"] == qid:
            answer += m["text"]
        elif m["t"] == "answer.done" and m["query_id"] == qid:
            done = m
        elif m["t"] == "error" and m.get("query_id") == qid:
            raise AssertionError(m)
    return answer, audio, done


@needs_models
def test_session_query_and_sync(monkeypatch, unused_port=9555):
    if not REAL:
        monkeypatch.setattr(llm, "stream_chat", scripted)

    async def run():
        task = await start_server({"port": unused_port})
        try:
            async with connect(f"ws://127.0.0.1:{unused_port}/ear/v1") as bad:
                await bad.send(protocol.encode("hello", token="WRONG123", client={}, caps={}))
                with pytest.raises(ConnectionClosed) as e:
                    await bad.recv()
                assert e.value.rcvd.code == protocol.CLOSE_BAD_TOKEN
            async with connect(f"ws://127.0.0.1:{unused_port}/ear/v1", max_size=2**22) as ws:
                await ws.send(
                    protocol.encode(
                        "hello", token="GOODTOKN", client={"app": "test"}, caps={"pcm_in": 16000}
                    )
                )
                assert json.loads(await ws.recv())["t"] == "welcome"
                await ws.send(protocol.encode("ping", ts=1.25))
                assert json.loads(await ws.recv()) == {"t": "pong", "ts": 1.25}
                await ws.send(
                    protocol.encode(
                        "session.start", session_id="s1", locale="en-US", mode="ambient"
                    )
                )
                pcm = wav_pcm(FIXTURES / "lecture_en_01.wav")
                facts = json.loads((FIXTURES / "lecture_en_01.facts.json").read_text())
                queries = [
                    q
                    for q in json.loads((FIXTURES / "queries/en.json").read_text())
                    if q["fixture"] == "lecture_en_01"
                ]
                finals, results, sent = 0, [], 0
                for f, q in zip(facts, queries if REAL else queries[:2]):
                    upto = (
                        int((f["t"] + 1) * 32000) & ~1
                    )  # stream audio up to just after the fact (fast, not real time)
                    for i in range(sent, upto, 3200):
                        await ws.send(
                            protocol.binary(
                                protocol.KIND_PCM_IN, i // 640, pcm[i : min(i + 3200, upto)]
                            )
                        )
                    sent = upto
                    # ask once the Mac has transcribed past the fact (≤ 5 s), as a user asks about what was just said
                    deadline = asyncio.get_running_loop().time() + 5
                    while True:
                        try:
                            m = json.loads(await asyncio.wait_for(ws.recv(), 0.25))
                            finals += m["t"] == "asr.final"
                            if m["t"] == "asr.final" and m["t1"] >= f["t"] - 0.5:
                                break
                        except TimeoutError:
                            if asyncio.get_running_loop().time() > deadline:
                                break
                    results.append(
                        (
                            f,
                            *await ask(
                                ws,
                                f"q{len(results)}",
                                FIXTURES / "queries" / q["wav"],
                                at=f["t"] + 5,
                            ),
                        )
                    )
                await ws.send(protocol.encode("session.stop", session_id="s1"))
                while (m := json.loads(await ws.recv()))["t"] != "segments.sync":
                    finals += m["t"] == "asr.final"
                assert finals > 0 and len(m["segments"]) >= finals - len(results)
                return results
        finally:
            task.cancel()

    results = asyncio.run(run())
    assert all(audio > 0 for _, _, audio, _ in results), "TTS audio frames for every answer"
    assert all(
        {"asrFinal", "contextReady", "done"} <= done["latency"].keys() for *_, done in results
    )
    if REAL:
        correct = sum(
            any(m.lower() in a.lower() for m in f["must_contain"]) for f, a, _, _ in results
        )
        first_audio = statistics.median(d["latency"].get("ttsFirstAudio", 99) for *_, d in results)
        print(
            f"earbridge e2e: {correct}/{len(results)} correct, first audio p50 {first_audio:.2f} s"
        )
        rows = [{"device": "mac-arm64 (localhost WebSocket)", "tier": "mac", "model": d["model"], "speechEnd": 0.0,
                 **{k: v for k, v in d["latency"].items() if k != "queryEnd"},
                 "audioOutStart": d["latency"].get("ttsFirstAudio"), "answer": a, "question": d.get("question")}
                for _, a, _, d in results]  # fmt: skip
        raw = config.REPO / "docs/evidence/raw/latency_mac-arm64_mac_lecture_en_01.json"
        raw.parent.mkdir(parents=True, exist_ok=True)
        raw.write_text(json.dumps(rows, indent=2) + "\n")
        assert correct >= 9
        assert first_audio <= 1.5
