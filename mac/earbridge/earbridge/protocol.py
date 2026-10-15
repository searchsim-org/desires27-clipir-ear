"""Phone ↔ Mac protocol v1 (HANDOVER §7, docs/PROTOCOL.md).

MESSAGES is the single definition: `python -m earbridge.protocol` writes docs/protocol/<type>.schema.json (shared with
Swift's ProtocolCodecTests); `validate()` checks every inbound control message before use (ADR-016: no pydantic).
Binary frames: [1 byte kind][4 bytes LE uint32 seq][payload]; kind 0x01 PCM16 16 kHz phone→mac, 0x02 PCM16 24 kHz
mac→phone (TTS), 0x03 Opus (reserved).
"""

import json
import struct
import sys
from pathlib import Path

S = {"type": "string"}
N = {"type": "number"}
INT = {"type": "integer"}
SEGMENT = {
    "type": "object",
    "required": ["t0", "t1", "text"],
    "properties": {"t0": N, "t1": N, "text": S, "speaker": S, "id": INT},
}
# type → (required fields, optional fields); every message also has "t" and optional "id".
MESSAGES: dict[str, tuple[dict, dict]] = {
    # phone → mac
    "hello": (
        {
            "token": S,
            "client": {
                "type": "object",
                "properties": {"app": S, "version": S, "device": S, "os": S},
            },
            "caps": {"type": "object", "properties": {"pcm_in": INT}},
        },
        {},
    ),  # fmt: skip
    "session.start": ({"session_id": S, "locale": S, "mode": S}, {}),
    "session.stop": ({"session_id": S}, {}),
    "query.begin": ({"query_id": S, "session_id": S}, {}),
    "query.end": (
        {"query_id": S, "window_seconds": N},
        {
            "segments": {"type": "array", "items": SEGMENT},
            "notes": {"type": "array", "items": S},
            "at": N,
        },
    ),  # fmt: skip
    "query.cancel": ({"query_id": S}, {}),
    "ping": ({"ts": N}, {}),
    # mac → phone
    "welcome": (
        {
            "server": {
                "type": "object",
                "properties": {"version": S, "models": {"type": "object"}},
            },
            "session_token": S,
        },
        {},
    ),  # fmt: skip
    "asr.partial": (
        {"session_id": S, "text": S, "t0": N, "t1": N},
        {"query_id": S, "confidence": N, "speaker": S},
    ),
    "asr.final": (
        {"session_id": S, "text": S, "t0": N, "t1": N},
        {"query_id": S, "confidence": N, "speaker": S},
    ),
    "answer.token": ({"query_id": S, "text": S}, {"knowledge_tier": S}),
    "answer.sentence": ({"query_id": S, "text": S}, {"knowledge_tier": S}),
    "answer.action": ({"query_id": S, "action": {"type": "object"}}, {}),
    "answer.done": (
        {
            "query_id": S,
            "prompt_tokens": INT,
            "completion_tokens": INT,
            "model": S,
            "latency": {"type": "object"},
        },
        {"knowledge_tier": S, "question": S, "intent": S},
    ),  # fmt: skip
    "tts.start": ({"query_id": S, "sample_rate": INT}, {}),
    "tts.end": ({"query_id": S}, {}),
    "pong": ({"ts": N}, {}),
    "error": ({"code": S, "message": S}, {"query_id": S}),
    "segments.sync": ({"session_id": S, "segments": {"type": "array", "items": SEGMENT}}, {}),
}

KIND_PCM_IN, KIND_PCM_TTS, KIND_OPUS = 0x01, 0x02, 0x03
CLOSE_BAD_TOKEN = 4401
SCHEMA_DIR = Path(__file__).resolve().parents[3] / "docs/protocol"


def schema(t: str) -> dict:
    required, optional = MESSAGES[t]
    props = {"t": {"const": t}, "id": S, **required, **optional}
    return {"$schema": "https://json-schema.org/draft/2020-12/schema", "$id": f"clipir-ear/v1/{t}", "title": t,
            "type": "object", "required": ["t", *required], "properties": props}  # fmt: skip


class ProtocolError(ValueError):
    pass


_TYPES = {"string": str, "number": (int, float), "integer": int, "object": dict, "array": list}


def validate(msg: dict) -> dict:
    """Checks type, required fields and their JSON types (shallow; the full schemas are checked in tests)."""
    t = msg.get("t")
    if t not in MESSAGES:
        raise ProtocolError(f"unknown message type {t!r}")
    required, optional = MESSAGES[t]
    for name, spec in {**required, **optional}.items():
        if name not in msg:
            if name in required:
                raise ProtocolError(f"{t}: missing {name}")
            continue
        want = _TYPES[spec["type"]]
        if not isinstance(msg[name], want) or (
            spec["type"] in ("number", "integer") and isinstance(msg[name], bool)
        ):
            raise ProtocolError(f"{t}: {name} must be {spec['type']}")
    return msg


def encode(t: str, **fields) -> str:
    return json.dumps(validate({"t": t, **fields}), separators=(",", ":"))


def binary(kind: int, seq: int, payload: bytes) -> bytes:
    return struct.pack("<BI", kind, seq & 0xFFFFFFFF) + payload


def parse_binary(frame: bytes) -> tuple[int, int, bytes]:
    if len(frame) < 5:
        raise ProtocolError("binary frame shorter than its 5-byte header")
    kind, seq = struct.unpack("<BI", frame[:5])
    return kind, seq, frame[5:]


def new_id() -> str:
    import uuid

    return str(uuid.uuid4())


def write_schemas(directory: Path = SCHEMA_DIR) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    for t in MESSAGES:
        (directory / f"{t}.schema.json").write_text(json.dumps(schema(t), indent=2) + "\n")


if __name__ == "__main__":
    write_schemas()
    print(f"wrote {len(MESSAGES)} schemas to {SCHEMA_DIR}", file=sys.stderr)
