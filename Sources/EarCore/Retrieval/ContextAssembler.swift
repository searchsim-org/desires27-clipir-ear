import Foundation

public enum Tier: String, Codable, Sendable { case phone, mac }

/// Window + retrieval + notes with token budgeting (§8.2). 1 token ≈ 4 characters.
public struct ContextAssembler: Sendable {
    public struct Context: Sendable {
        public var windowSeconds: TimeInterval
        public var window: [Segment]
        public var retrieved: [Segment]
        public var notes: [String]
        public var minutes: Int?
    }

    let store: SQLiteTranscriptStore
    let embedder: (any Embedder)?
    let intents: IntentDetector

    public init(
        store: SQLiteTranscriptStore, embedder: (any Embedder)? = nil, intents: IntentDetector = IntentDetector()
    ) {
        (self.store, self.embedder, self.intents) = (store, embedder, intents)
    }

    public static func tokens(_ s: String) -> Int { (s.count + 3) / 4 }

    public func windowSeconds(for intent: Intent, question: String) -> (TimeInterval, Int?) {
        switch intent {
        case .explainLast: return (60, nil)
        case .expand: return (180, nil)
        case .summarizeWindow:
            let n = intents.minutes(in: question) ?? 2
            return (Double(n) * 60, n)
        case .whoSaid: return (300, nil)
        default: return (60, nil)
        }
    }

    /// `at`: pipeline time of the question (nil = latest segment). `budget`: whole-prompt token budget.
    public func assemble(question: String, intent: Intent, at: TimeInterval? = nil, tier: Tier = .phone) async throws
        -> Context
    {
        let budget = tier == .phone ? 2000 : 6000
        let (w, minutes) = windowSeconds(for: intent, question: question)
        var window = try await store.window(seconds: w, before: at)
        while window.count > 1, Self.tokens(window.map(\.text).joined(separator: "\n")) > 1200 { window.removeFirst() }

        var retrieved: [Segment] = []
        if intent != .explainLast {
            let inWindow = Set(window.compactMap(\.id))
            let cutoff = at ?? .infinity
            let lexical = try await store.searchLexical(question, k: 8).filter {
                !inWindow.contains($0.id ?? -1) && $0.t0 <= cutoff
            }
            var scores: [Int64: (Segment, Double)] = [:]
            for (rank, s) in lexical.enumerated() { scores[s.id!] = (s, 0.5 * (1 - Double(rank) / 8)) }
            if let embedder {
                let v = try await embedder.embed("search_query: " + question)
                for (s, cos) in try await store.searchVector(v, k: 8)
                where !inWindow.contains(s.id ?? -1) && s.t0 <= cutoff {
                    scores[s.id!] = (s, (scores[s.id!]?.1 ?? 0) + 0.5 * Double(cos))
                }
            }
            retrieved = scores.values.sorted { $0.1 > $1.1 }.prefix(5).map(\.0).sorted { $0.t0 < $1.t0 }
        }

        var notes: [String] = []
        var noteTokens = 0
        for p in try await store.pinned() where !window.contains(where: { $0.id == p.id }) {
            noteTokens += Self.tokens(p.text)
            if noteTokens > 400 { break }
            notes.append(p.text)
        }
        // Whole-prompt budget (≈ 300 tokens for system + question + template): drop retrieved first, then old window.
        func total() -> Int {
            300 + Self.tokens((window + retrieved).map(\.text).joined(separator: "\n") + notes.joined(separator: "\n"))
        }
        while total() > budget, !retrieved.isEmpty { retrieved.removeFirst() }
        while total() > budget, window.count > 1 { window.removeFirst() }
        return Context(windowSeconds: w, window: window, retrieved: retrieved, notes: notes, minutes: minutes)
    }
}

/// Deterministic 64-d word hashing; for tests and as a no-model fallback.
public struct HashEmbedder: Embedder {
    public let dimension = 64
    public init() {}
    public func embed(_ text: String) async throws -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        for w in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var h: UInt64 = 1_469_598_103_934_665_603  // FNV-1a
            for b in w.utf8 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
            v[Int(h % UInt64(dimension))] += 1
        }
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n == 0 ? v : v.map { $0 / n }
    }
}

/// Embeds new segments in the background (P3.3): at most `perSecond` segments per second (phone: 1).
public final class EmbeddingIndexer: Sendable {
    private let store: SQLiteTranscriptStore
    private let embedder: any Embedder
    private let model: String

    public init(store: SQLiteTranscriptStore, embedder: any Embedder, model: String) {
        (self.store, self.embedder, self.model) = (store, embedder, model)
    }

    /// Embeds everything pending now; returns the count. Used by tests and the CLI.
    @discardableResult
    public func catchUp() async throws -> Int {
        var n = 0
        while true {
            let batch = try await store.segmentsWithoutEmbedding(limit: 16)
            if batch.isEmpty { return n }
            for s in batch {
                try await store.setEmbedding(
                    segmentID: s.id!, vector: try await embedder.embed("search_document: " + s.text), model: model)
                n += 1
            }
        }
    }

    public func run(perSecond: Double = 1) async {
        while !Task.isCancelled {
            if let s = try? await store.segmentsWithoutEmbedding(limit: 1).first,
                let v = try? await embedder.embed("search_document: " + s.text)
            {
                try? await store.setEmbedding(segmentID: s.id!, vector: v, model: model)
            }
            try? await Task.sleep(for: .seconds(1 / perSecond))
        }
    }
}
