"""Wizard of Oz (user studies): the console's answer is spoken back, no earlier than the enforced delay."""

import asyncio
import json
import time
import urllib.request

from conftest import FIXTURES
from test_e2e_ws import ask, needs_models
from websockets.asyncio.client import connect

from earbridge import config, protocol, server, wizard
from earbridge.store import Store


def _get(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=2) as r:
        return json.load(r)


@needs_models
def test_wizard_answer_is_spoken_after_delay(port=9581):
    desk = wizard.Desk(delay=2.0, bank=["The optimizer is called Adam."])

    async def wizard_person():  # what the human does at the console: wait for a question, click the prepared answer
        loop = asyncio.get_running_loop()
        while True:
            state = await loop.run_in_executor(None, _get, f"http://127.0.0.1:{port}/wizard/state")
            if state["pending"]:
                p = state["pending"][0]
                text = urllib.request.quote(state["bank"][0])
                await loop.run_in_executor(
                    None,
                    _get,
                    f"http://127.0.0.1:{port}/wizard/answer?qid={p['query_id']}&text={text}",
                )
                return p["question"]
            await asyncio.sleep(0.1)

    async def run():
        ready = asyncio.Event()
        task = asyncio.create_task(server.run("127.0.0.1", port, "GOODTOKN", config.LLM_MODEL, Store(),
                                              advertise=False, ready=ready, desk=desk))  # fmt: skip
        await ready.wait()
        page = (
            await asyncio.get_running_loop().run_in_executor(  # off the loop: the server runs on it
                None,
                lambda: urllib.request.urlopen(f"http://127.0.0.1:{port}/wizard", timeout=2)
                .read()
                .decode(),
            )
        )
        assert "Wizard console" in page
        try:
            async with connect(f"ws://127.0.0.1:{port}/ear/v1", max_size=2**22) as ws:
                await ws.send(protocol.encode("hello", token="GOODTOKN", client={}, caps={}))
                assert json.loads(await ws.recv())["t"] == "welcome"
                person = asyncio.create_task(wizard_person())
                t0 = time.monotonic()
                answer, audio, done = await asyncio.wait_for(
                    ask(ws, "w1", FIXTURES / "queries/lecture_en_01_q01.wav"), 30
                )
                return answer, audio, done, await asyncio.wait_for(person, 5), time.monotonic() - t0
        finally:
            task.cancel()

    answer, audio, done, heard, _ = asyncio.run(run())
    assert "Adam" in answer and audio > 0
    assert done["model"] == "wizard"
    assert done["latency"]["llmFirstToken"] >= 2.0, "answer must not come before the enforced delay"
    assert heard, "the wizard saw the recognised question"
