"""Mac-side export (P6.4): derived measures as JSON.
Same privacy rules as Sources/EarCore/Export (docs/PRIVACY.md)."""

import json
import statistics
from datetime import UTC, datetime

from .store import Store


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, UTC).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def measures(
    store: Store, session: str, include_qa: bool = False, include_transcript: bool = False
) -> dict:
    db = store.db
    s = db.execute("SELECT * FROM sessions WHERE id=?", (session,)).fetchone()
    if s is None:
        raise KeyError(session)
    qs = [dict(r) for r in db.execute("SELECT * FROM voice_queries WHERE session_id=?", (session,))]
    lat = [json.loads(q["latency_json"]) for q in qs]
    first = [x["ttsFirstAudio"] for x in lat if "ttsFirstAudio" in x]
    by_intent, tiers = {}, {}
    for q in qs:
        by_intent[q["intent"]] = by_intent.get(q["intent"], 0) + 1
        tiers[q["tier"]] = tiers.get(q["tier"], 0) + 1
    doc = {
        "export_schema_version": 1, "session": {"id": session, "started_at": s["started_at"], "ended_at": s["ended_at"],
                                                "tier_policy": s["tier_policy"]},
        "measures": {"query_count": len(qs), "queries_by_intent": by_intent, "tier_split": tiers,
                     "latency_first_audio_p50": statistics.median(first) if first else None},
    }  # fmt: skip
    if include_qa:
        doc["queries"] = [
            {"question": q["question"], "answer": q["answer"], "intent": q["intent"]} for q in qs
        ]
    if include_transcript:
        doc["transcript"] = [
            {"t0": r["t0"], "t1": r["t1"], "text": r["text"]} for r in store.segments(session)
        ]
    return doc
