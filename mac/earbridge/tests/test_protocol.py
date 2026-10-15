import json

import jsonschema
import pytest

from earbridge import protocol

EXAMPLES = {
    "hello": {
        "token": "ABCD2345",
        "client": {"app": "ClipIREar", "version": "0.1", "device": "iPhone", "os": "18.6"},
        "caps": {"pcm_in": 16000},
    },  # fmt: skip
    "session.start": {"session_id": "s", "locale": "en-US", "mode": "ambient"},
    "session.stop": {"session_id": "s"},
    "query.begin": {"query_id": "q", "session_id": "s"},
    "query.end": {
        "query_id": "q",
        "window_seconds": 60,
        "segments": [{"t0": 0, "t1": 1.5, "text": "hi"}],
        "notes": [],
    },
    "query.cancel": {"query_id": "q"},
    "ping": {"ts": 1.5},
    "welcome": {"server": {"version": "0.1.0", "models": {"llm": "x"}}, "session_token": "t"},
    "asr.partial": {"session_id": "s", "text": "hel", "t0": 0, "t1": 0.4},
    "asr.final": {"session_id": "s", "text": "hello", "t0": 0, "t1": 0.6, "query_id": "q"},
    "answer.token": {"query_id": "q", "text": "The"},
    "answer.sentence": {"query_id": "q", "text": "The deadline moves to Friday."},
    "answer.action": {"query_id": "q", "action": {"note": {"text": "x"}}},
    "answer.done": {
        "query_id": "q",
        "prompt_tokens": 10,
        "completion_tokens": 5,
        "model": "m",
        "latency": {"done": 1.0},
    },
    "tts.start": {"query_id": "q", "sample_rate": 24000},
    "tts.end": {"query_id": "q"},
    "pong": {"ts": 1.5},
    "error": {"code": "x", "message": "y"},
    "segments.sync": {"session_id": "s", "segments": []},
}


def test_committed_schemas_match_the_spec():
    for t in protocol.MESSAGES:
        assert json.loads(
            (protocol.SCHEMA_DIR / f"{t}.schema.json").read_text()
        ) == protocol.schema(t), t
    assert len(list(protocol.SCHEMA_DIR.glob("*.schema.json"))) == len(protocol.MESSAGES)


@pytest.mark.parametrize("t", list(protocol.MESSAGES))
def test_every_message_validates_and_round_trips(t):
    msg = json.loads(protocol.encode(t, **EXAMPLES[t]))
    jsonschema.validate(msg, protocol.schema(t))
    assert protocol.validate(msg) == msg


def test_invalid_messages_are_rejected():
    with pytest.raises(protocol.ProtocolError):
        protocol.validate({"t": "ping"})
    with pytest.raises(protocol.ProtocolError):
        protocol.validate({"t": "ping", "ts": "soon"})
    with pytest.raises(protocol.ProtocolError):
        protocol.validate({"t": "launch.missiles"})


def test_binary_frames():
    frame = protocol.binary(protocol.KIND_PCM_TTS, 2**32 + 7, b"\x01\x02")
    assert protocol.parse_binary(frame) == (protocol.KIND_PCM_TTS, 7, b"\x01\x02")
