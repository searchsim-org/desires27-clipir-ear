import asyncio
import json
import urllib.request

from earbridge import brain, export, server
from earbridge.store import Store


def populated() -> tuple[Store, str]:
    s = Store()
    sid = s.start_session("s1")
    s.append(sid, 0, 4, "SECRET TRANSCRIPT", "t")
    s.save_query(sid, "SECRET QUESTION", "explainLast", 60, [], "SECRET ANSWER", "transcript", "m", 10, 5,
                 {"ttsFirstAudio": 0.9})  # fmt: skip
    return s, sid


def test_measures_have_no_text_by_default():
    s, sid = populated()
    doc = export.measures(s, sid)
    assert "SECRET" not in json.dumps(doc)
    assert doc["measures"]["query_count"] == 1 and doc["measures"]["latency_first_audio_p50"] == 0.9
    assert "SECRET QUESTION" in json.dumps(export.measures(s, sid, include_qa=True))


def test_export_endpoint_and_action_flag():
    s, sid = populated()

    async def run():
        ready = asyncio.Event()
        task = asyncio.create_task(
            server.run("127.0.0.1", 9561, "TOKEN123", "m", s, advertise=False, ready=ready)
        )
        await ready.wait()
        body = await asyncio.to_thread(
            lambda: urllib.request.urlopen(
                f"http://127.0.0.1:9561/ear/v1/export?session={sid}"
            ).read()
        )
        task.cancel()
        return json.loads(body)

    doc = asyncio.run(run())
    assert doc["measures"]["query_count"] == 1 and "SECRET" not in json.dumps(doc)
    assert brain.is_action("remind me to email Anna tomorrow", "remindMe")
    assert brain.is_action("put the review in my calendar on Friday", "freeform")
    assert not brain.is_action("what did the speaker just say", "explainLast")
