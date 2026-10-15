import Foundation
import GRDB

/// One row of `voice_queries` (§6).
public struct VoiceQuery: Sendable, Codable, Equatable {
    public var id: Int64?
    public var sessionID: String
    public var askedAt: Date
    public var question: String
    public var intent: String
    public var windowSeconds: Double
    public var retrievedIDs: [Int64]
    public var answer: String
    public var tier: String
    public var knowledgeTier: String
    public var model: String
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var latencyJSON: String
    public var actionProposed: String?
    public var actionResponse: String?

    public init(
        sessionID: String, question: String, intent: String, windowSeconds: Double = 0, retrievedIDs: [Int64] = [],
        answer: String = "", tier: String = "phone", knowledgeTier: String = "none", model: String = "",
        latencyJSON: String = "{}"
    ) {
        (self.sessionID, self.askedAt, self.question, self.intent) = (sessionID, Date(), question, intent)
        (self.windowSeconds, self.retrievedIDs, self.answer, self.tier) = (windowSeconds, retrievedIDs, answer, tier)
        (self.knowledgeTier, self.model, self.latencyJSON) = (knowledgeTier, model, latencyJSON)
    }
}

extension SQLiteTranscriptStore {
    /// Inserts or updates (when `q.id` is set) a voice query; returns its id.
    @discardableResult
    public func save(_ q: VoiceQuery) async throws -> Int64 {
        let ids = String(data: try JSONEncoder().encode(q.retrievedIDs), encoding: .utf8)!
        return try await db.write { db in
            let args: StatementArguments = [
                q.sessionID, q.askedAt.timeIntervalSince1970, q.question, q.intent, q.windowSeconds,
                ids, q.answer, q.tier, q.knowledgeTier, q.model, q.promptTokens, q.completionTokens, q.latencyJSON,
                q.actionProposed, q.actionResponse,
            ]
            if let id = q.id {
                try db.execute(
                    sql: """
                        UPDATE voice_queries SET session_id=?, asked_at=?, question=?, intent=?, window_seconds=?, retrieved_ids=?,
                          answer=?, tier=?, knowledge_tier=?, model=?, prompt_tokens=?, completion_tokens=?, latency_json=?,
                          action_proposed=?, action_response=? WHERE id=\(id)
                        """, arguments: args)
                return id
            }
            try db.execute(
                sql: """
                    INSERT INTO voice_queries (session_id, asked_at, question, intent, window_seconds, retrieved_ids, answer, tier,
                      knowledge_tier, model, prompt_tokens, completion_tokens, latency_json, action_proposed, action_response)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: args)
            return db.lastInsertedRowID
        }
    }

    public func queries(session: String? = nil) async throws -> [VoiceQuery] {
        try await db.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM voice_queries \(session == nil ? "" : "WHERE session_id = ?") ORDER BY id",
                arguments: session.map { [$0] } ?? [])
            return rows.map { r in
                var q = VoiceQuery(
                    sessionID: r["session_id"], question: r["question"], intent: r["intent"],
                    windowSeconds: r["window_seconds"], answer: r["answer"], tier: r["tier"],
                    knowledgeTier: r["knowledge_tier"],
                    model: r["model"], latencyJSON: r["latency_json"])
                q.id = r["id"]
                q.askedAt = Date(timeIntervalSince1970: r["asked_at"])
                q.retrievedIDs =
                    (try? JSONDecoder().decode([Int64].self, from: Data((r["retrieved_ids"] as String).utf8))) ?? []
                (q.promptTokens, q.completionTokens) = (r["prompt_tokens"], r["completion_tokens"])
                (q.actionProposed, q.actionResponse) = (r["action_proposed"], r["action_response"])
                return q
            }
        }
    }
}
