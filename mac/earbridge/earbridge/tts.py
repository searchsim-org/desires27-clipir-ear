"""Mac-tier TTS (ADR-015): a warm `EarCLI tts-stream` worker (AVSpeechSynthesizer, Apple platform API).
Sentences in, PCM16 mono 24 kHz chunks out as they are synthesised; one worker per connection."""

import asyncio
import struct
from collections.abc import AsyncIterator

from . import config

SAMPLE_RATE = 24_000


class Speaker:
    def __init__(self):
        self.proc: asyncio.subprocess.Process | None = None
        self.lock = asyncio.Lock()

    async def start(self) -> "Speaker":
        self.proc = await asyncio.create_subprocess_exec(
            str(config.EARCLI), "tts-stream", stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )  # fmt: skip
        return self

    async def speak(self, sentence: str) -> AsyncIterator[bytes]:
        """Yields PCM chunks for one sentence as soon as the synthesizer produces them."""
        async with self.lock:
            self.proc.stdin.write(sentence.replace("\n", " ").encode() + b"\n")
            await self.proc.stdin.drain()
            while True:
                (n,) = struct.unpack("<I", await self.proc.stdout.readexactly(4))
                if n == 0:
                    return
                yield await self.proc.stdout.readexactly(n)

    async def synthesize(self, sentence: str) -> bytes:
        return b"".join([c async for c in self.speak(sentence)])

    def close(self) -> None:
        if self.proc and self.proc.returncode is None:
            self.proc.kill()
