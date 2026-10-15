import Foundation
import GRDB
import Synchronization

public struct Segment: Codable, Sendable, Identifiable, Equatable {
    public var id: Int64?
    public var sessionID: String
    public var t0: TimeInterval, t1: TimeInterval  // pipeline clock
    public var wallClock: Date  // retention + display
    public var text: String
    public var speaker: String  // "you" | "other-1" | … | "unknown"
    public var confidence: Double?
    public var source: String
    public var engine: String
    public var pinned: Bool

    public init(
        id: Int64? = nil, sessionID: String, t0: TimeInterval, t1: TimeInterval, wallClock: Date = Date(),
        text: String, speaker: String = "unknown", confidence: Double? = nil, source: String, engine: String,
        pinned: Bool = false
    ) {
        (self.id, self.sessionID, self.t0, self.t1, self.wallClock, self.text) = (
            id, sessionID, t0, t1, wallClock, text
        )
        (self.speaker, self.confidence, self.source, self.engine, self.pinned) = (
            speaker, confidence, source, engine, pinned
        )
    }
}

public protocol TranscriptStore: Sendable {
    func append(_ s: Segment) async throws -> Int64
    func window(seconds: TimeInterval, before: TimeInterval?) async throws -> [Segment]
    func searchLexical(_ q: String, k: Int) async throws -> [Segment]
    func searchVector(_ v: [Float], k: Int) async throws -> [(Segment, Float)]
    func purge(olderThan: Date) async throws -> Int
    func purge(lastSeconds: TimeInterval) async throws -> Int  // "forget the last N minutes"
    func pin(_ id: Int64, _ pinned: Bool) async throws
}

public protocol Embedder: Sendable {
    var dimension: Int { get }
    func embed(_ text: String) async throws -> [Float]
}

public struct SessionInfo: Sendable {
    public var id: String = UUID().uuidString
    public var mode = "ambient"
    public var captureSource: String
    public var tierPolicy = "auto"
    public var retentionSeconds = 1800
    public var appVersion = EarCore.version
    public var deviceModel: String
    public var osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    public init(captureSource: String, deviceModel: String = "unknown") {
        self.captureSource = captureSource
        self.deviceModel = deviceModel
    }
}

/// `ear.db` (§6) on GRDB. File databases use WAL; `inMemory` is for tests.
public final class SQLiteTranscriptStore: TranscriptStore, @unchecked Sendable {
    public let db: any DatabaseWriter

    public static func file(at url: URL) throws -> SQLiteTranscriptStore {
        try SQLiteTranscriptStore(db: DatabasePool(path: url.path, configuration: config()))
    }
    public static func inMemory() throws -> SQLiteTranscriptStore {
        try SQLiteTranscriptStore(db: DatabaseQueue(configuration: config()))
    }

    private static func config() -> Configuration {
        var c = Configuration()
        c.foreignKeysEnabled = true
        return c
    }

    init(db: any DatabaseWriter) throws {
        self.db = db
        try Self.migrator.migrate(db)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(
                sql: """
                    CREATE TABLE sessions (
                      id TEXT PRIMARY KEY, started_at REAL NOT NULL, ended_at REAL, mode TEXT NOT NULL,
                      capture_source TEXT NOT NULL, tier_policy TEXT NOT NULL, retention_seconds INTEGER NOT NULL,
                      app_version TEXT NOT NULL, device_model TEXT NOT NULL, os_version TEXT NOT NULL);
                    CREATE TABLE audio_segments (
                      id INTEGER PRIMARY KEY,
                      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                      t0 REAL NOT NULL, t1 REAL NOT NULL, wall_clock REAL NOT NULL, text TEXT NOT NULL,
                      speaker TEXT NOT NULL DEFAULT 'unknown', confidence REAL, source TEXT NOT NULL, engine TEXT NOT NULL,
                      pinned INTEGER NOT NULL DEFAULT 0, audio_retained INTEGER NOT NULL DEFAULT 0);
                    CREATE INDEX idx_segments_wall ON audio_segments(wall_clock);
                    CREATE VIRTUAL TABLE segments_fts USING fts5(text, content='audio_segments', content_rowid='id', tokenize='unicode61');
                    CREATE TRIGGER segments_ai AFTER INSERT ON audio_segments BEGIN
                      INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text); END;
                    CREATE TRIGGER segments_ad AFTER DELETE ON audio_segments BEGIN
                      INSERT INTO segments_fts(segments_fts, rowid, text) VALUES ('delete', old.id, old.text); END;
                    CREATE TRIGGER segments_au AFTER UPDATE OF text ON audio_segments BEGIN
                      INSERT INTO segments_fts(segments_fts, rowid, text) VALUES ('delete', old.id, old.text);
                      INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text); END;
                    CREATE TABLE embeddings (
                      segment_id INTEGER PRIMARY KEY REFERENCES audio_segments(id) ON DELETE CASCADE,
                      model TEXT NOT NULL, dim INTEGER NOT NULL, vec BLOB NOT NULL);
                    CREATE TABLE voice_queries (
                      id INTEGER PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                      asked_at REAL NOT NULL, question TEXT NOT NULL, intent TEXT NOT NULL, window_seconds REAL NOT NULL,
                      retrieved_ids TEXT NOT NULL, answer TEXT NOT NULL, tier TEXT NOT NULL, knowledge_tier TEXT NOT NULL,
                      model TEXT NOT NULL, prompt_tokens INTEGER, completion_tokens INTEGER, latency_json TEXT NOT NULL,
                      action_proposed TEXT, action_response TEXT);
                    CREATE TABLE purges (
                      id INTEGER PRIMARY KEY, session_id TEXT, at REAL NOT NULL, kind TEXT NOT NULL, arg REAL,
                      removed_segments INTEGER NOT NULL);
                    CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    """)
        }
        m.registerMigration("v2-notes") { db in  // P6.3: local notes
            try db.execute(
                sql:
                    "CREATE TABLE notes (id INTEGER PRIMARY KEY, created_at REAL NOT NULL, text TEXT NOT NULL, session_id TEXT)"
            )
        }
        m.registerMigration("v3-device-metrics") { db in  // P8.5: MetricKit, aggregates only leave the app
            try db.execute(
                sql: """
                    CREATE TABLE device_metrics (id INTEGER PRIMARY KEY, received_at REAL NOT NULL, kind TEXT NOT NULL,
                      cpu_seconds REAL, peak_memory_mb REAL, hangs INTEGER NOT NULL DEFAULT 0,
                      crashes INTEGER NOT NULL DEFAULT 0, json TEXT NOT NULL)
                    """)
        }
        return m
    }

    // MARK: sessions

    private let session = Mutex<String?>(nil)
    public var currentSession: String? { session.withLock { $0 } }
    public func useSession(_ id: String?) { session.withLock { $0 = id } }

    @discardableResult
    public func startSession(_ s: SessionInfo, makeCurrent: Bool = true) async throws -> String {
        try await db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (id, started_at, mode, capture_source, tier_policy, retention_seconds,
                      app_version, device_model, os_version) VALUES (?,?,?,?,?,?,?,?,?)
                    """,
                arguments: [
                    s.id, Date().timeIntervalSince1970, s.mode, s.captureSource, s.tierPolicy,
                    s.retentionSeconds, s.appVersion, s.deviceModel, s.osVersion,
                ])
        }
        if makeCurrent { useSession(s.id) }
        return s.id
    }

    public func endSession(_ id: String) async throws {
        try await db.write {
            try $0.execute(
                sql: "UPDATE sessions SET ended_at = ? WHERE id = ?", arguments: [Date().timeIntervalSince1970, id])
        }
    }

    // MARK: TranscriptStore

    public func append(_ s: Segment) async throws -> Int64 {
        try await db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audio_segments (session_id, t0, t1, wall_clock, text, speaker, confidence, source, engine, pinned)
                    VALUES (?,?,?,?,?,?,?,?,?,?)
                    """,
                arguments: [
                    s.sessionID, s.t0, s.t1, s.wallClock.timeIntervalSince1970, s.text, s.speaker, s.confidence,
                    s.source, s.engine, s.pinned,
                ])
            return db.lastInsertedRowID
        }
    }

    /// Segments of the current session ending within `seconds` before `before` (pipeline clock; default: latest).
    public func window(seconds: TimeInterval, before: TimeInterval?) async throws -> [Segment] {
        guard let session = currentSession else { return [] }
        return try await db.read { db in
            let end =
                try before ?? Double.fetchOne(
                    db, sql: "SELECT max(t1) FROM audio_segments WHERE session_id = ?", arguments: [session]) ?? 0
            return try Self.segments(
                db, "WHERE session_id = ? AND t1 > ? AND t0 <= ? ORDER BY t0", [session, end - seconds, end])
        }
    }

    public func searchLexical(_ q: String, k: Int) async throws -> [Segment] {
        let terms = Self.ftsQuery(q)
        guard !terms.isEmpty else { return [] }
        return try await db.read { db in
            try Self.segments(
                db,
                """
                JOIN segments_fts f ON f.rowid = s.id WHERE segments_fts MATCH ? ORDER BY bm25(segments_fts) LIMIT ?
                """, [terms, k])
        }
    }

    public func searchVector(_ v: [Float], k: Int) async throws -> [(Segment, Float)] {
        try await db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT segment_id, vec FROM embeddings")
            let scored = rows.map { r -> (Int64, Float) in
                let vec = (r["vec"] as Data).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                return (r["segment_id"], Self.cosine(v, vec))
            }.sorted { $0.1 > $1.1 }.prefix(k)
            let byID = try Dictionary(
                uniqueKeysWithValues: Self.segments(
                    db, "WHERE s.id IN (\(scored.map { "\($0.0)" }.joined(separator: ",")))", []
                )
                .map { ($0.id!, $0) })
            return scored.compactMap { id, score in byID[id].map { ($0, score) } }
        }
    }

    public func setEmbedding(segmentID: Int64, vector: [Float], model: String) async throws {
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        try await db.write {
            try $0.execute(
                sql: "INSERT OR REPLACE INTO embeddings (segment_id, model, dim, vec) VALUES (?,?,?,?)",
                arguments: [segmentID, model, vector.count, data])
        }
    }

    public func segmentsWithoutEmbedding(limit: Int) async throws -> [Segment] {
        try await db.read {
            try Self.segments(
                $0, "WHERE s.id NOT IN (SELECT segment_id FROM embeddings) ORDER BY s.id LIMIT ?", [limit])
        }
    }

    /// Retention (§6): unpinned rows older than the cut-off. Logged with counts only.
    public func purge(olderThan: Date) async throws -> Int {
        try await purge(
            kind: "older_than", arg: olderThan.timeIntervalSince1970,
            sql: "DELETE FROM audio_segments WHERE pinned = 0 AND wall_clock < ?", [olderThan.timeIntervalSince1970])
    }

    /// "Forget the last N minutes": everything in that span, pinned or not (device check).
    public func purge(lastSeconds: TimeInterval) async throws -> Int {
        let cut = Date().timeIntervalSince1970 - lastSeconds
        return try await purge(
            kind: "last_seconds", arg: lastSeconds, sql: "DELETE FROM audio_segments WHERE wall_clock >= ?", [cut])
    }

    public func purgeAll() async throws -> Int {
        try await purge(kind: "all", arg: nil, sql: "DELETE FROM audio_segments", [])
    }

    private func purge(kind: String, arg: Double?, sql: String, _ args: StatementArguments) async throws -> Int {
        let session = currentSession
        return try await db.write { db in
            try db.execute(sql: sql, arguments: args)
            let n = db.changesCount
            try db.execute(
                sql: "INSERT INTO purges (session_id, at, kind, arg, removed_segments) VALUES (?,?,?,?,?)",
                arguments: [session, Date().timeIntervalSince1970, kind, arg, n])
            return n
        }
    }

    public func pin(_ id: Int64, _ pinned: Bool) async throws {
        try await db.write {
            try $0.execute(sql: "UPDATE audio_segments SET pinned = ? WHERE id = ?", arguments: [pinned, id])
        }
    }

    /// P8.3: segments overlapping a recorded span keep a pointer that their audio exists (Recordings/).
    public func markAudioRetained(session: String, from t0: TimeInterval, to t1: TimeInterval) async throws {
        try await db.write {
            try $0.execute(
                sql: "UPDATE audio_segments SET audio_retained = 1 WHERE session_id = ? AND t1 >= ? AND t0 <= ?",
                arguments: [session, t0, t1])
        }
    }

    public func pinned() async throws -> [Segment] {
        try await db.read { try Self.segments($0, "WHERE s.pinned = 1 ORDER BY s.t0", []) }
    }

    public func all(session: String? = nil) async throws -> [Segment] {
        try await db.read { db in
            if let session { return try Self.segments(db, "WHERE s.session_id = ? ORDER BY s.t0", [session]) }
            return try Self.segments(db, "ORDER BY s.wall_clock", [])
        }
    }

    public func count() async throws -> Int {
        try await db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM audio_segments") ?? 0 }
    }

    // MARK: helpers

    static func segments(_ db: Database, _ tail: String, _ args: StatementArguments) throws -> [Segment] {
        try Row.fetchAll(db, sql: "SELECT s.* FROM audio_segments s \(tail)", arguments: args).map { r in
            Segment(
                id: r["id"], sessionID: r["session_id"], t0: r["t0"], t1: r["t1"],
                wallClock: Date(timeIntervalSince1970: r["wall_clock"]), text: r["text"], speaker: r["speaker"],
                confidence: r["confidence"], source: r["source"], engine: r["engine"], pinned: r["pinned"])
        }
    }

    /// Turns free text into an FTS5 OR-query of quoted terms (no syntax injection from user text).
    static func ftsQuery(_ q: String) -> String {
        let stop: Set<String> = [
            "the", "a", "an", "what", "did", "just", "say", "about", "is", "was", "of", "to", "and",
            "in", "on", "speaker", "he", "she", "they", "it", "that", "this", "me", "tell", "more",
        ]
        let words = q.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter {
            $0.count > 1 && !stop.contains($0)
        }
        return words.map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return na == 0 || nb == 0 ? 0 : dot / (na.squareRoot() * nb.squareRoot())
    }
}

/// Runs retention every 30 s and on demand (app foreground) (§6).
public final class RetentionPolicy: Sendable {
    private let store: SQLiteTranscriptStore
    public let retentionSeconds: TimeInterval
    private let task = Mutex<Task<Void, Never>?>(nil)

    public init(store: SQLiteTranscriptStore, retentionSeconds: TimeInterval = 1800) {
        self.store = store
        self.retentionSeconds = min(86_400, max(60, retentionSeconds))
    }

    @discardableResult
    public func runOnce() async throws -> Int {
        try await store.purge(olderThan: Date().addingTimeInterval(-retentionSeconds))
    }

    public func start(every interval: Duration = .seconds(30)) {
        let t = Task { [weak self] in
            while !Task.isCancelled {
                _ = try? await self?.runOnce()
                try? await Task.sleep(for: interval)
            }
        }
        task.withLock {
            $0?.cancel()
            $0 = t
        }
    }

    public func stop() {
        task.withLock {
            $0?.cancel()
            $0 = nil
        }
    }
}
