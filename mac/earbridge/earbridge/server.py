"""earbridge WebSocket server (HANDOVER §7, P5.1–P5.4): one Connection per phone."""

import asyncio
import json
import subprocess
import sys
import threading
import time
from collections import defaultdict, deque
from http import HTTPStatus
from urllib.parse import parse_qs, urlparse

from websockets.asyncio.server import serve
from websockets.datastructures import Headers
from websockets.exceptions import ConnectionClosed
from websockets.http11 import Response

from . import asr, brain, config, export, llm, protocol, tls, tts, wizard
from .store import Store

_failures: dict[str, deque] = defaultdict(deque)  # ip → recent bad hellos (rate limit, P5.4)


def log(*a) -> None:
    print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


class Connection:
    def __init__(self, ws, store: Store, token: str, model: str, desk: "wizard.Desk | None" = None):
        self.ws, self.store, self.token, self.model, self.desk = ws, store, token, model, desk
        self.session: str | None = None
        self.ambient: asr.AsrProcess | None = None
        self.ambient_reader: asyncio.Task | None = None
        self.question: asr.AsrProcess | None = None
        self.answer_task: asyncio.Task | None = None
        self.cancel = threading.Event()
        self.tts: tts.Speaker | None = None
        self.spare: asr.AsrProcess | None = None  # warm question worker (model already loaded)
        self.ip = ws.remote_address[0] if ws.remote_address else "?"

    async def send(self, t: str, **fields) -> None:
        await self.ws.send(protocol.encode(t, **fields))

    async def run(self) -> None:
        if not await self.handshake():
            return
        try:
            async for raw in self.ws:
                if isinstance(raw, bytes):
                    self.on_binary(raw)
                else:
                    try:
                        await self.on_message(protocol.validate(json.loads(raw)))
                    except (protocol.ProtocolError, json.JSONDecodeError) as e:
                        await self.send("error", code="bad_message", message=str(e))
        except ConnectionClosed:
            pass
        finally:
            await self.close()

    async def handshake(self) -> bool:
        recent = _failures[self.ip]
        while recent and recent[0] < time.time() - 60:
            recent.popleft()
        if len(recent) >= 5:
            log("rate-limited hello from", self.ip)
            await self.ws.close(4429, "too many attempts")
            return False
        try:
            hello = protocol.validate(json.loads(await asyncio.wait_for(self.ws.recv(), 10)))
        except Exception:
            await self.ws.close(4400, "expected hello")
            return False
        if hello["t"] != "hello" or hello["token"] != self.token:
            recent.append(time.time())
            log("rejected hello from", self.ip)
            await self.ws.close(protocol.CLOSE_BAD_TOKEN, "bad token")
            return False
        log("client", self.ip, json.dumps(hello.get("client", {})))
        self.tts = await tts.Speaker().start()  # warm synthesizer for this phone
        await self.tts.synthesize(
            "Ready."
        )  # first synthesis is ~1.4 s cold; pay it at connect, not at the first answer
        self.spare = await asr.AsrProcess(utterance=True).start()
        await self.send("welcome", server={"version": config.VERSION,
                        "models": {"asr": "sherpa:zipformer-en-2023-06-26", "llm": self.model, "tts": "macos-say"}},
                        session_token=protocol.new_id())  # fmt: skip
        return True

    def on_binary(self, frame: bytes) -> None:
        kind, _seq, payload = protocol.parse_binary(frame)
        if kind != protocol.KIND_PCM_IN:
            return
        (self.question or self.ambient or _Null).feed(payload)

    async def on_message(self, m: dict) -> None:
        t = m["t"]
        if t == "ping":
            await self.send("pong", ts=m["ts"])
        elif t == "session.start":
            self.session = self.store.start_session(m["session_id"])
            self.ambient = await asr.AsrProcess().start()
            self.ambient_reader = asyncio.create_task(self.read_ambient())
        elif t == "session.stop":
            await self.stop_ambient()
            segs = [{"t0": s["t0"], "t1": s["t1"], "text": s["text"], "speaker": s["speaker"], "id": s["id"]}
                    for s in self.store.segments(m["session_id"])]  # fmt: skip
            await self.send("segments.sync", session_id=m["session_id"], segments=segs)
            self.store.end_session(m["session_id"])
        elif t == "query.begin":
            if self.answer_task:
                self.cancel.set()  # barge-in
            self.question = self.spare or await asr.AsrProcess(utterance=True).start()
            self.spare = await asr.AsrProcess(utterance=True).start()  # ready for the next question
        elif t == "query.end":
            self.cancel = threading.Event()
            self.answer_task = asyncio.create_task(self.answer(m))
        elif t == "query.cancel":
            self.cancel.set()

    async def read_ambient(self) -> None:
        async for r in self.ambient.results():
            fields = dict(session_id=self.session, text=r["text"], t0=r["t0"], t1=r["t1"])
            if r["type"] == "final":
                self.store.append(self.session, r["t0"], r["t1"], r["text"], r["engine"])
            await self.send(f"asr.{r['type']}", **fields)

    async def stop_ambient(self) -> None:
        if self.ambient:
            await self.ambient.close()
            if self.ambient_reader:
                await self.ambient_reader
            self.ambient = None

    async def answer(self, m: dict) -> None:
        qid, start = m["query_id"], time.monotonic()
        mark = lambda: round(time.monotonic() - start, 3)  # noqa: E731 — seconds since query.end arrived
        latency: dict[str, float] = {"queryEnd": 0.0}
        q_asr, self.question = self.question, None
        question = await q_asr.finish_utterance() if q_asr else ""
        latency["asrFinal"] = mark()
        if not question:
            await self.send("error", code="no_question", message="no question heard", query_id=qid)
            return
        await self.send(
            "asr.final", session_id=self.session or "", query_id=qid, text=question, t0=0.0, t1=0.0
        )
        intent = brain.detect(question)
        if brain.is_action(question, intent):  # ADR-018: the phone proposes, approves and executes
            await self.send(
                "answer.action", query_id=qid, action={"question": question, "intent": intent}
            )
            await self.send("answer.done", query_id=qid, prompt_tokens=0, completion_tokens=0, model=self.model,
                            latency=latency, question=question, intent=intent)  # fmt: skip
            return
        segments = m.get("segments") or (self.store.segments(self.session) if self.session else [])
        ctx = brain.assemble(
            question, intent, segments, self.store.search(question, 8, self.session), m.get("at")
        )
        system, user = brain.prompts(question, intent, ctx, m.get("notes", []))
        latency["contextReady"] = mark()
        splitter, sentences = brain.SentenceSplitter(first_clause=True), asyncio.Queue()
        speaker = asyncio.create_task(self.speak(qid, sentences, latency, mark))
        text, n = "", 0
        try:
            if self.desk:  # Wizard of Oz: a person answers, same voice and channel (user studies)
                context = "\n".join(s["text"] for s in ctx["window"])
                source = wizard.stream(self.desk, qid, question, context, start, self.cancel)
            else:
                source = llm.stream_chat(system, user, model=self.model, cancel=self.cancel)
            async for delta in source:
                if not text:
                    latency["llmFirstToken"] = mark()
                text, n = text + delta, n + 1
                await self.send("answer.token", query_id=qid, text=delta)
                for s in splitter.push(delta):
                    latency.setdefault("llmFirstSentence", mark())
                    await self.send("answer.sentence", query_id=qid, text=s)
                    await sentences.put(s)
        except Exception as e:
            await self.send("error", code="llm_failed", message=str(e)[:200], query_id=qid)
        if (rest := splitter.flush()) and not self.cancel.is_set():
            latency.setdefault("llmFirstSentence", mark())
            await self.send("answer.sentence", query_id=qid, text=rest)
            await sentences.put(rest)
        await sentences.put(None)
        await speaker
        answer, knowledge = brain.parse_source(text)
        latency["done"] = mark()
        await self.send("answer.done", query_id=qid, prompt_tokens=brain.tokens(system + user), completion_tokens=n,
                        model="wizard" if self.desk else self.model, latency=latency, knowledge_tier=knowledge, question=question, intent=intent)  # fmt: skip
        if self.session:
            self.store.save_query(self.session, question, intent, ctx["window_seconds"], [], answer, knowledge, self.model,
                                  brain.tokens(system + user), n, latency)  # fmt: skip
        log(f"query {qid[:8]} {intent} {json.dumps(latency)}")

    async def speak(self, qid: str, sentences: asyncio.Queue, latency: dict, mark) -> None:
        """Sentence n+1 is synthesised while n is being sent (P4.2 behaviour, Mac side)."""
        seq, started = 0, False
        while (s := await sentences.get()) is not None:
            if self.cancel.is_set():
                continue
            async for pcm in self.tts.speak(s):
                if self.cancel.is_set():
                    continue
                if not started:
                    await self.send("tts.start", query_id=qid, sample_rate=tts.SAMPLE_RATE)
                    latency["ttsFirstAudio"] = mark()
                    started = True
                await self.ws.send(protocol.binary(protocol.KIND_PCM_TTS, seq, pcm))
                seq += 1
        if started:
            await self.send("tts.end", query_id=qid)

    async def close(self) -> None:
        self.cancel.set()
        for p in (self.ambient, self.question, self.spare, self.tts):
            if p:
                (p.kill if hasattr(p, "kill") else p.close)()
        log("closed", self.ip)


class _Null:
    @staticmethod
    def feed(_):
        pass


def make_http(store: Store, fp: str = "none", desk: "wizard.Desk | None" = None):
    def http(connection, request):
        """Non-WebSocket requests: /health and GET /ear/v1/export?session=… (P6.5, derived measures only)."""
        url = urlparse(request.path)
        if url.path == "/ear/v1":
            return None  # WebSocket upgrade
        if url.path == "/health":
            return _json(HTTPStatus.OK, {"ok": True, "version": config.VERSION, "fp": fp})
        if desk and url.path.startswith("/wizard"):
            peer = connection.remote_address[0] if connection.remote_address else ""
            if peer not in ("127.0.0.1", "::1"):  # the console is for the wizard at this Mac only
                return _json(HTTPStatus.FORBIDDEN, {"error": "wizard console is localhost only"})
            if url.path == "/wizard":
                return Response(HTTPStatus.OK, "OK", Headers({"Content-Type": "text/html; charset=utf-8"}),
                                wizard.page().encode())  # fmt: skip
            if url.path == "/wizard/state":
                return _json(HTTPStatus.OK, desk.state())
            if url.path == "/wizard/answer":
                q = parse_qs(url.query)
                ok = desk.answer(q.get("qid", [""])[0], q.get("text", [""])[0])
                return _json(HTTPStatus.OK if ok else HTTPStatus.CONFLICT, {"ok": ok})
        if url.path == "/ear/v1/export":
            session = parse_qs(url.query).get("session", [""])[0]
            try:
                return _json(HTTPStatus.OK, export.measures(store, session))
            except KeyError:
                return _json(HTTPStatus.NOT_FOUND, {"error": "unknown session"})
        return Response(HTTPStatus.NOT_FOUND, "Not Found", Headers(), b"not found\n")

    return http


def _json(status: HTTPStatus, obj: dict) -> Response:
    return Response(
        status,
        status.phrase,
        Headers({"Content-Type": "application/json"}),
        json.dumps(obj).encode(),
    )


def bonjour(port: int, fp: str):
    """Registers _clipir-ear._tcp with macOS dns-sd (zeroconf is LGPL, ADR-016)."""
    name = config.load().get("name") or __import__("socket").gethostname().split(".")[0]
    return subprocess.Popen(["dns-sd", "-R", name, "_clipir-ear._tcp", "local", str(port), "v=1", f"name={name}", f"fp={fp}"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)  # fmt: skip


async def run(
    host: str,
    port: int,
    token: str,
    model: str,
    store: Store,
    advertise: bool = True,
    ready=None,
    use_tls: bool = False,
    desk: "wizard.Desk | None" = None,
) -> None:
    fp = tls.fingerprint() if use_tls else "none"
    announce = bonjour(port, fp) if advertise else None
    try:
        async with serve(lambda ws: Connection(ws, store, token, model, desk).run(), host, port, process_request=make_http(store, fp, desk),
                         max_size=2**22, ssl=tls.context() if use_tls else None) as server:  # fmt: skip
            log(
                f"earbridge {config.VERSION} on {'wss' if use_tls else 'ws'}://{host}:{port}/ear/v1  model={model}  fp={fp}"
            )
            if ready:
                ready.set()
            await server.serve_forever()
    finally:
        if announce:
            announce.terminate()
