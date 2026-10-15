import Foundation
import GRDB

/// Review & Export (P6.4, PRIVACY §8): derived measures by default; question/answer text and the transcript only
/// when the user ticks them for this export. This is the only code that produces data meant to leave the app.
public struct Exporter: Sendable {
    public static let schemaVersion = 2  // v2 (P8.7): device, cue, recording and MetricKit measures
    public struct Options: Sendable {
        public var includeQuestionsAndAnswers = false
        public var includeTranscript = false
        public init(includeQuestionsAndAnswers: Bool = false, includeTranscript: Bool = false) {
            (self.includeQuestionsAndAnswers, self.includeTranscript) = (includeQuestionsAndAnswers, includeTranscript)
        }
    }

    public struct SessionSummary: Sendable, Identifiable {
        public let id: String, startedAt: Date, endedAt: Date?, mode: String, captureSource: String
        public let segmentCount: Int, queryCount: Int
    }

    let store: SQLiteTranscriptStore
    public init(store: SQLiteTranscriptStore) { self.store = store }

    public func sessions() async throws -> [SessionSummary] {
        try await store.db.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT s.*, (SELECT count(*) FROM audio_segments a WHERE a.session_id = s.id) AS n_seg,
                      (SELECT count(*) FROM voice_queries q WHERE q.session_id = s.id) AS n_q
                    FROM sessions s ORDER BY started_at DESC
                    """
            ).map { r in
                SessionSummary(
                    id: r["id"], startedAt: Date(timeIntervalSince1970: r["started_at"]),
                    endedAt: (r["ended_at"] as Double?).map(Date.init(timeIntervalSince1970:)), mode: r["mode"],
                    captureSource: r["capture_source"], segmentCount: r["n_seg"], queryCount: r["n_q"])
            }
        }
    }

    /// The export document for one session (JSON-serialisable dictionary).
    public func export(session: String, options: Options = Options()) async throws -> [String: Any] {
        let queries = try await store.queries(session: session)
        let (info, purges, retained, metrics): (Row?, [Row], Int, Row?) = try await store.db.read { db in
            (
                try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [session]),
                try Row.fetchAll(
                    db, sql: "SELECT kind, arg, removed_segments, at FROM purges WHERE session_id = ?",
                    arguments: [session]),
                try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM audio_segments WHERE session_id = ? AND audio_retained = 1",
                    arguments: [session]) ?? 0,
                // MetricKit arrives daily, not per session: the last 7 days, sums only (P8.5)
                try Row.fetchOne(
                    db,
                    sql: """
                        SELECT count(*) AS payloads, sum(cpu_seconds) AS cpu, max(peak_memory_mb) AS mem,
                          sum(hangs) AS hangs, sum(crashes) AS crashes FROM device_metrics WHERE received_at > ?
                        """, arguments: [Date().timeIntervalSince1970 - 7 * 86_400])
            )
        }
        guard let info else { throw EarError.notFound("session \(session)") }
        let latencies = queries.compactMap { q in
            (try? JSONSerialization.jsonObject(with: Data(q.latencyJSON.utf8))) as? [String: Any]
        }
        func stage(_ s: String) -> [Double] {
            latencies.compactMap { l in (l[s] as? Double).map { $0 - ((l["speechEnd"] as? Double) ?? 0) } }
        }
        func pct(_ xs: [Double], _ p: Double) -> Double? {
            let s = xs.sorted()
            return s.isEmpty ? nil : s[min(s.count - 1, Int((p * Double(s.count - 1)).rounded()))]
        }
        var byIntent: [String: Int] = [:]
        var tiers: [String: Int] = [:]
        var responses: [String: Int] = [:]
        for q in queries {
            byIntent[q.intent, default: 0] += 1
            tiers[q.tier, default: 0] += 1
            if let r = q.actionResponse { responses[r, default: 0] += 1 }
        }
        let firstAudio = stage("audioOutStart")
        let firstToken = stage("llmFirstToken")
        var doc: [String: Any] = [
            "export_schema_version": Self.schemaVersion, "app_version": EarCore.version,
            "exported_at": Date().timeIntervalSince1970,
            "session": [
                "id": session, "started_at": info["started_at"] as Double,
                "ended_at": (info["ended_at"] as Double?) as Any,
                "mode": info["mode"] as String, "capture_source": info["capture_source"] as String,
                "tier_policy": info["tier_policy"] as String, "retention_seconds": info["retention_seconds"] as Int,
            ],
            "measures": [
                "query_count": queries.count, "queries_by_intent": byIntent, "tier_split": tiers,
                "fallbacks": latencies.filter { $0["fallback"] as? Bool == true }.count,
                "latency_first_audio_p50": pct(firstAudio, 0.5) as Any,
                "latency_first_audio_p95": pct(firstAudio, 0.95) as Any,
                "latency_first_token_p50": pct(firstToken, 0.5) as Any,
                "action_responses": responses,
                "action_acceptance_rate": responses.isEmpty
                    ? NSNull()
                    : Double(responses["accepted", default: 0] + responses["edited", default: 0])
                        / Double(responses.values.reduce(0, +)),
                "cue_count": byIntent["cue", default: 0],
                "audio_retained_segments": retained,
                "memory_footprint_mb_max": latencies.compactMap { $0["memory_footprint_mb"] as? Double }.max() as Any,
                "thermal_states": Dictionary(
                    latencies.compactMap { $0["thermal_state"] as? String }.map { ($0, 1) }, uniquingKeysWith: +),
                "battery_drop": { () -> Any in
                    let b = latencies.compactMap { $0["battery_level"] as? Double }
                    return b.count > 1 ? b.first! - b.last! : NSNull()
                }(),
                "purge_count": purges.count,
                "purged_segments": purges.reduce(0) { $0 + ($1["removed_segments"] as Int) },
            ] as [String: Any],
            "device_metrics": [
                "payloads": metrics?["payloads"] as Int? ?? 0, "cpu_seconds": (metrics?["cpu"] as Double?) as Any,
                "peak_memory_mb": (metrics?["mem"] as Double?) as Any, "hangs": metrics?["hangs"] as Int? ?? 0,
                "crashes": metrics?["crashes"] as Int? ?? 0,
            ] as [String: Any],
        ]
        if options.includeQuestionsAndAnswers {
            doc["queries"] = queries.map { q in
                [
                    "asked_at": q.askedAt.timeIntervalSince1970, "question": q.question, "answer": q.answer,
                    "intent": q.intent,
                    "tier": q.tier, "knowledge_tier": q.knowledgeTier, "action_response": q.actionResponse as Any,
                ] as [String: Any]
            }
        }
        if options.includeTranscript {
            doc["transcript"] = try await store.all(session: session).map {
                ["t0": $0.t0, "t1": $0.t1, "text": $0.text, "speaker": $0.speaker] as [String: Any]
            }
        }
        return doc
    }

    /// The measures as display strings (Sendable, for the Review screen).
    public func measureSummary(session: String) async throws -> [String: String] {
        let m = try await export(session: session)["measures"] as? [String: Any] ?? [:]
        return m.mapValues { v in
            if let d = v as? Double { return String(format: "%.2f", d) }
            if v is NSNull { return "—" }
            return "\(v)"
        }
    }

    /// JSON + Markdown summary in the app's temporary directory, ready for the share sheet.
    public func write(session: String, options: Options = Options()) async throws -> [URL] {
        let doc = try await export(session: session, options: options)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipir-ear-export", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = dir.appendingPathComponent("session-\(session.prefix(8)).json")
        try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]).write(to: json)
        let m = doc["measures"] as! [String: Any]
        let md = dir.appendingPathComponent("session-\(session.prefix(8)).md")
        let lines = [
            "# ClipIR Ear session \(session.prefix(8))", "", "- Questions: \(m["query_count"]!)",
            "- By intent: \(m["queries_by_intent"]!)", "- Tier split: \(m["tier_split"]!)",
            "- First audio p50: \(m["latency_first_audio_p50"]!) s", "- Actions: \(m["action_responses"]!)",
            "- Purges: \(m["purge_count"]!) (\(m["purged_segments"]!) segments)",
            "- Questions/answers included: \(options.includeQuestionsAndAnswers ? "yes" : "no")",
            "- Transcript included: \(options.includeTranscript ? "yes" : "no")",
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: md, atomically: true, encoding: .utf8)
        return [json, md]
    }
}
