"""ASR through the Swift EarCLI worker (ADR-015): PCM16 16 kHz in on stdin, JSON lines out."""

import asyncio
import json
from collections.abc import AsyncIterator

from . import config


class AsrProcess:
    """One `EarCLI asr-stream` subprocess: ambient (VAD + endpointing) or a single utterance (until close)."""

    def __init__(self, utterance: bool = False):
        self.utterance = utterance
        self.proc: asyncio.subprocess.Process | None = None

    async def start(self) -> "AsrProcess":
        args = [str(config.EARCLI), "asr-stream"] + (["--utterance"] if self.utterance else [])
        self.proc = await asyncio.create_subprocess_exec(
            *args,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        return self

    def feed(self, pcm16: bytes) -> None:
        if self.proc and self.proc.stdin and not self.proc.stdin.is_closing():
            self.proc.stdin.write(pcm16)

    async def results(self) -> AsyncIterator[dict]:
        assert self.proc and self.proc.stdout
        while line := await self.proc.stdout.readline():
            yield json.loads(line)

    async def close(self) -> None:
        """Ends input; the worker finalises pending audio and exits."""
        if self.proc and self.proc.stdin and not self.proc.stdin.is_closing():
            self.proc.stdin.close()

    async def finish_utterance(self) -> str:
        """Utterance mode: close input and return the final text."""
        await self.close()
        texts = [r["text"] async for r in self.results() if r["type"] == "final"]
        await self.proc.wait()
        return " ".join(texts)

    def kill(self) -> None:
        if self.proc and self.proc.returncode is None:
            self.proc.kill()
