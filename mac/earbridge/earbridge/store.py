"""Mac mirror of ear.db (HANDOVER §6) on stdlib sqlite3; same tables as the phone's GRDB store."""

import json
import sqlite3
import time
import uuid
from pathlib import Path

SCHEMA = """
PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, started_at REAL NOT NULL, ended_at REAL, mode TEXT NOT NULL,
  capture_source TEXT NOT NULL, tier_policy TEXT NOT NULL, retention_seconds INTEGER NOT NULL, app_version TEXT NOT NULL,
  device_model TEXT NOT NULL, os_version TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS audio_segments (id INTEGER PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, t0 REAL NOT NULL, t1 REAL NOT NULL,
  wall_clock REAL NOT NULL, text TEXT NOT NULL, speaker TEXT NOT NULL DEFAULT 'unknown', confidence REAL,
  source TEXT NOT NULL, engine TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0, audio_retained INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS idx_segments_wall ON audio_segments(wall_clock);
CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts USING fts5(text, content='audio_segments', content_rowid='id', tokenize='unicode61');
CREATE TRIGGER IF NOT EXISTS segments_ai AFTER INSERT ON audio_segments BEGIN
  INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text); END;
CREATE TRIGGER IF NOT EXISTS segments_ad AFTER DELETE ON audio_segments BEGIN
  INSERT INTO segments_fts(segments_fts, rowid, text) VALUES ('delete', old.id, old.text); END;
CREATE TABLE IF NOT EXISTS embeddings (segment_id INTEGER PRIMARY KEY REFERENCES audio_segments(id) ON DELETE CASCADE,
  model TEXT NOT NULL, dim INTEGER NOT NULL, vec BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS voice_queries (id INTEGER PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, asked_at REAL NOT NULL, question TEXT NOT NULL,
  intent TEXT NOT NULL, window_seconds REAL NOT NULL, retrieved_ids TEXT NOT NULL, answer TEXT NOT NULL, tier TEXT NOT NULL,
  knowledge_tier TEXT NOT NULL, model TEXT NOT NULL, prompt_tokens INTEGER, completion_tokens INTEGER,
  latency_json TEXT NOT NULL, action_proposed TEXT, action_response TEXT);
CREATE TABLE IF NOT EXISTS purges (id INTEGER PRIMARY KEY, session_id TEXT, at REAL NOT NULL, kind TEXT NOT NULL, arg REAL,
  removed_segments INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""

STOP = {"the", "a", "an", "what", "did", "just", "say", "about", "is", "was", "of", "to", "and", "in", "on", "speaker",
        "he", "she", "they", "it", "that", "this", "me", "tell", "more"}  # fmt: skip


class Store:
    def __init__(self, path: Path | str = ":memory:"):
        if path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(str(path), check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)

    def start_session(
        self, session_id: str | None = None, *, source: str = "remote", device: str = "phone"
    ) -> str:
        sid = session_id or str(uuid.uuid4())
        self.db.execute(
            "INSERT OR IGNORE INTO sessions VALUES (?,?,NULL,'ambient',?,'mac',1800,'earbridge',?,'macOS')",
            (sid, time.time(), source, device),
        )
        self.db.commit()
        return sid

    def end_session(self, sid: str) -> None:
        self.db.execute("UPDATE sessions SET ended_at=? WHERE id=?", (time.time(), sid))
        self.db.commit()

    def append(
        self, sid: str, t0: float, t1: float, text: str, engine: str, speaker: str = "unknown"
    ) -> int:
        cur = self.db.execute(
            "INSERT INTO audio_segments (session_id,t0,t1,wall_clock,text,speaker,source,engine) VALUES (?,?,?,?,?,?,?,?)",
            (sid, t0, t1, time.time(), text, speaker, "remote", engine),
        )
        self.db.commit()
        return cur.lastrowid

    def segments(self, sid: str) -> list[dict]:
        rows = self.db.execute(
            "SELECT * FROM audio_segments WHERE session_id=? ORDER BY t0", (sid,)
        )
        return [dict(r) for r in rows]

    def search(self, question: str, k: int = 8, sid: str | None = None) -> list[dict]:
        words = [
            w
            for w in "".join(c if c.isalnum() else " " for c in question.lower()).split()
            if len(w) > 1 and w not in STOP
        ]
        if not words:
            return []
        q = " OR ".join(f'"{w}"' for w in words)
        sql = ("SELECT s.* FROM audio_segments s JOIN segments_fts f ON f.rowid = s.id WHERE segments_fts MATCH ?"
               + (" AND s.session_id = ?" if sid else "") + " ORDER BY bm25(segments_fts) LIMIT ?")  # fmt: skip
        return [dict(r) for r in self.db.execute(sql, (q, sid, k) if sid else (q, k))]

    def save_query(self, sid: str, question: str, intent: str, window: float, retrieved: list[int], answer: str,
                   knowledge: str, model: str, prompt_tokens: int, completion_tokens: int, latency: dict) -> int:  # fmt: skip
        cur = self.db.execute(
            "INSERT INTO voice_queries (session_id,asked_at,question,intent,window_seconds,retrieved_ids,answer,tier,"
            "knowledge_tier,model,prompt_tokens,completion_tokens,latency_json) VALUES (?,?,?,?,?,?,?,'mac',?,?,?,?,?)",
            (sid, time.time(), question, intent, window, json.dumps(retrieved), answer, knowledge, model,
             prompt_tokens, completion_tokens, json.dumps(latency)),
        )  # fmt: skip
        self.db.commit()
        return cur.lastrowid
