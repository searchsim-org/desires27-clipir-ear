# Data model (ear.db)

The phone keeps its data in one SQLite database managed by GRDB (`SQLiteTranscriptStore` in `Sources/EarCore/Memory/TranscriptStore.swift`). Migrations: `v1` creates the core tables, `v2-notes` adds `notes`, `v3-device-metrics` adds `device_metrics`.

`earbridge` keeps a mirror at `~/Library/Application Support/ClipIREar/ear.db` with the `v1` tables only (`mac/earbridge/earbridge/store.py`). The Mac writes the segments it recognised and the questions it answered, with `tier = 'mac'`.

```sql
PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;

CREATE TABLE sessions (
  id TEXT PRIMARY KEY,                 -- UUID
  started_at REAL NOT NULL,            -- unix seconds
  ended_at REAL,
  mode TEXT NOT NULL,                  -- 'ambient' | 'query-only'
  capture_source TEXT NOT NULL,        -- e.g. 'mic', 'file:<name>'; 'remote' on the Mac
  tier_policy TEXT NOT NULL,           -- 'auto' | 'phone' | 'mac'
  retention_seconds INTEGER NOT NULL,
  app_version TEXT NOT NULL, device_model TEXT NOT NULL, os_version TEXT NOT NULL
);

CREATE TABLE audio_segments (
  id INTEGER PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  t0 REAL NOT NULL, t1 REAL NOT NULL,  -- pipeline clock, seconds
  wall_clock REAL NOT NULL,            -- unix seconds at t1
  text TEXT NOT NULL,
  speaker TEXT NOT NULL DEFAULT 'unknown',
  confidence REAL,
  source TEXT NOT NULL, engine TEXT NOT NULL,
  pinned INTEGER NOT NULL DEFAULT 0,
  audio_retained INTEGER NOT NULL DEFAULT 0   -- 1 only for segments captured while Record was on
);
CREATE INDEX idx_segments_wall ON audio_segments(wall_clock);
CREATE VIRTUAL TABLE segments_fts USING fts5(text, content='audio_segments', content_rowid='id', tokenize='unicode61');
-- triggers segments_ai, segments_ad (and segments_au on the phone) keep segments_fts in sync

CREATE TABLE embeddings (
  segment_id INTEGER PRIMARY KEY REFERENCES audio_segments(id) ON DELETE CASCADE,
  model TEXT NOT NULL, dim INTEGER NOT NULL, vec BLOB NOT NULL   -- little-endian Float32
);

CREATE TABLE voice_queries (
  id INTEGER PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  asked_at REAL NOT NULL,
  question TEXT NOT NULL, intent TEXT NOT NULL,
  window_seconds REAL NOT NULL, retrieved_ids TEXT NOT NULL,     -- JSON array of segment ids
  answer TEXT NOT NULL, tier TEXT NOT NULL, knowledge_tier TEXT NOT NULL,
  model TEXT NOT NULL, prompt_tokens INTEGER, completion_tokens INTEGER,
  latency_json TEXT NOT NULL,                                     -- {stage: seconds}
  action_proposed TEXT, action_response TEXT                      -- 'accepted' | 'edited' | 'dismissed' | 'timeout'
);

CREATE TABLE purges (
  id INTEGER PRIMARY KEY, session_id TEXT, at REAL NOT NULL,
  kind TEXT NOT NULL,                  -- 'last_seconds' | 'older_than' | 'all'
  arg REAL, removed_segments INTEGER NOT NULL
);

CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);

-- phone only
CREATE TABLE notes (id INTEGER PRIMARY KEY, created_at REAL NOT NULL, text TEXT NOT NULL, session_id TEXT);

CREATE TABLE device_metrics (
  id INTEGER PRIMARY KEY, received_at REAL NOT NULL, kind TEXT NOT NULL,
  cpu_seconds REAL, peak_memory_mb REAL, hangs INTEGER NOT NULL DEFAULT 0,
  crashes INTEGER NOT NULL DEFAULT 0, json TEXT NOT NULL   -- MetricKit payloads
);
```

## Columns worth knowing

- `voice_queries.latency_json` holds the `LatencyTrace` stages in seconds since `pttDown` on the phone, or since `query.end` arrived on the Mac. Extra keys record context such as `fallback`, `memory_footprint_mb`, `thermal_state` and `battery_level`.
- `voice_queries.intent` also takes the values `purge` (a spoken "forget the last N minutes") and `cue` (a proactive cue), so those events are counted with the questions.
- `voice_queries.knowledge_tier` is the answer's `SOURCE:` line: `transcript`, `notes`, `general` or `none`.

## Rules

- `RetentionPolicy` runs every 30 s and when the app comes to the foreground: `DELETE FROM audio_segments WHERE pinned = 0 AND wall_clock < now - retention_seconds`. Retention is clamped to 60 to 86,400 s; the default is 1,800 s.
- "Forget the last N minutes" deletes every segment in that span, pinned or not.
- Every purge writes one `purges` row with counts only, never the deleted text.
- Raw audio goes to disk only while the user has Record on. The recorder writes a 16 kHz mono WAV to the app's `Documents/Recordings/` folder, and the Review screen lists it.
- The Mac mirror has no retention policy. Its segments stay until you delete the file.

## Export format

`Exporter` (`Sources/EarCore/Export/Exporter.swift`, `export_schema_version` 2) produces one JSON document per session:

- `session`: id, start and end, mode, capture source, tier policy, retention.
- `measures`: query count, queries by intent, tier split, fallbacks, first-audio latency p50 and p95, first-token latency p50, action responses and acceptance rate, cue count, retained-audio segments, peak memory footprint, thermal states, battery drop, purge count and purged segments.
- `device_metrics`: MetricKit sums over the last 7 days (payloads, CPU seconds, peak memory, hangs, crashes).
- `queries`: question, answer, intent, tier, knowledge tier and action response, only when the user ticks "include questions and answers".
- `transcript`: `t0`, `t1`, `text` and `speaker` per segment, only when the user ticks "include transcript".

`earbridge export --session <id>` and `GET /ear/v1/export` produce a smaller version 1 document from the Mac mirror with the same opt-in rules (`--include-qa`, `--include-transcript` on the command line; the HTTP endpoint never includes them).
