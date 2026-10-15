"""Ollama on localhost via its native /api/chat, streamed (stdlib only, ADR-016). Native, not /v1: only it accepts
`think: false`, and Gemma 4 otherwise spends the whole budget in a hidden reasoning channel."""

import asyncio
import json
import threading
import urllib.request
from collections.abc import AsyncIterator

from . import config


class Cancelled(Exception):
    pass


async def stream_chat(system: str, user: str, *, model: str | None = None, max_tokens: int = 220,
                      cancel: threading.Event | None = None) -> AsyncIterator[str]:  # fmt: skip
    """Yields text deltas. Runs the blocking HTTP read in a thread; `cancel` stops it between chunks."""
    body = json.dumps({
        "model": model or config.LLM_MODEL, "stream": True, "think": False,
        "options": {"temperature": 0, "num_predict": max_tokens},
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    }).encode()  # fmt: skip
    req = urllib.request.Request(
        f"{config.OLLAMA}/api/chat", data=body, headers={"Content-Type": "application/json"}
    )
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue = asyncio.Queue()
    cancel = cancel or threading.Event()

    def worker():
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                for raw in resp:  # NDJSON: {"message": {"content": …}, "done": bool}
                    if cancel.is_set():
                        break
                    chunk = json.loads(raw)
                    delta = chunk.get("message", {}).get("content") or ""
                    if delta:
                        loop.call_soon_threadsafe(queue.put_nowait, delta)
                    if chunk.get("done"):
                        break
        except Exception as e:  # surfaced to the caller
            loop.call_soon_threadsafe(queue.put_nowait, e)
        loop.call_soon_threadsafe(queue.put_nowait, None)

    threading.Thread(target=worker, daemon=True).start()
    while (item := await queue.get()) is not None:
        if isinstance(item, Exception):
            raise item
        yield item


def models() -> list[str]:
    with urllib.request.urlopen(f"{config.OLLAMA}/api/tags", timeout=3) as r:
        return [m["name"] for m in json.load(r)["models"]]


def warm(model: str | None = None) -> None:
    """1-token request so the model is resident (HANDOVER §17: Ollama slow first token)."""
    body = json.dumps(
        {
            "model": model or config.LLM_MODEL,
            "prompt": "hi",
            "stream": False,
            "options": {"num_predict": 1},
        }
    ).encode()
    urllib.request.urlopen(
        urllib.request.Request(f"{config.OLLAMA}/api/generate", data=body), timeout=120
    ).read()
