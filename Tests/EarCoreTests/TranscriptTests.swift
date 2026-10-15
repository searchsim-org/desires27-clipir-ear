import GRDB
import XCTest

@testable import EarCore

final class TranscriptStoreTests: XCTestCase {
    private func store(segments texts: [(Double, String)], wallOffset: TimeInterval = 0) async throws
        -> SQLiteTranscriptStore
    {
        let s = try SQLiteTranscriptStore.inMemory()
        let session = try await s.startSession(SessionInfo(captureSource: "test"))
        for (t, text) in texts {
            _ = try await s.append(
                Segment(
                    sessionID: session, t0: t, t1: t + 2, wallClock: Date().addingTimeInterval(wallOffset + t),
                    text: text, source: "test", engine: "scripted"))
        }
        return s
    }

    func testWindowAndLexicalSearchFindPlantedFact() async throws {
        let s = try await store(segments: [
            (0, "Welcome to the lecture"), (30, "The optimizer we use is called Adam"),
            (100, "Now let us talk about stability"),
        ])
        let w = try await s.window(seconds: 60, before: nil)
        XCTAssertEqual(w.map(\.text), ["Now let us talk about stability"])
        let hits = try await s.searchLexical("What did the speaker say about the optimizer?", k: 5)
        XCTAssertEqual(hits.first?.text, "The optimizer we use is called Adam")
        let quoteInjection = try await s.searchLexical("\" OR * NEAR(", k: 5)
        XCTAssertTrue(quoteInjection.isEmpty)
    }

    func testRetentionDeletesUnpinnedOldRowsAndKeepsPinned() async throws {
        let s = try await store(segments: [(0, "old one"), (1, "old pinned")], wallOffset: -4000)
        let pinnedID = try await s.all().first { $0.text == "old pinned" }!.id!
        try await s.pin(pinnedID, true)
        _ = try await s.append(
            Segment(sessionID: s.currentSession!, t0: 50, t1: 52, text: "fresh", source: "test", engine: "x"))
        let removed = try await RetentionPolicy(store: s, retentionSeconds: 1800).runOnce()
        XCTAssertEqual(removed, 1)
        let left = try await s.all().map(\.text)
        XCTAssertEqual(Set(left), ["old pinned", "fresh"])
        let fts = try await s.searchLexical("old one", k: 5)
        XCTAssertFalse(fts.contains { $0.text == "old one" }, "FTS index follows deletes")
    }

    func testPurgeLastSecondsCountsAndLogs() async throws {
        let s = try await store(segments: [(0, "a"), (1, "b")], wallOffset: -1200)  // 20 min ago
        for t in [10.0, 20, 30] {
            _ = try await s.append(
                Segment(sessionID: s.currentSession!, t0: t, t1: t + 1, text: "recent \(t)", source: "t", engine: "x"))
        }
        let removed = try await s.purge(lastSeconds: 600)
        XCTAssertEqual(removed, 3)
        let count = try await s.count()
        XCTAssertEqual(count, 2)
        let logged: Row? = try await s.db.read { db in
            try Row.fetchOne(db, sql: "SELECT kind, removed_segments FROM purges")
        }
        XCTAssertEqual(logged?["kind"], "last_seconds")
        XCTAssertEqual(logged?["removed_segments"], 3)
    }

    func testFileDatabaseUsesWAL() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ear-\(UUID()).db")
        let s = try SQLiteTranscriptStore.file(at: url)
        let mode = try s.db.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        XCTAssertEqual(mode, "wal")
    }

    func testVectorSearchRanksByCosine() async throws {
        let s = try await store(segments: [(0, "alpha"), (5, "beta")])
        let ids = try await s.all().map { $0.id! }
        try await s.setEmbedding(segmentID: ids[0], vector: [1, 0, 0], model: "t")
        try await s.setEmbedding(segmentID: ids[1], vector: [0, 1, 0], model: "t")
        let hits = try await s.searchVector([0.1, 0.9, 0], k: 1)
        XCTAssertEqual(hits.first?.0.text, "beta")
    }
}

final class ScriptedPipelineTests: XCTestCase {
    func testFinalsLandWithTimestampsFromVAD() async throws {
        // 1 s tone, 1 s silence, 1 s tone → two utterances with EnergyVAD
        let store = try SQLiteTranscriptStore.inMemory()
        let session = try await store.startSession(SessionInfo(captureSource: "test"))
        let source = ToneSource(pattern: [true, false, true])
        let pipeline = AmbientPipeline(
            store: store, vad: EnergyVAD(), recognizer: ScriptedRecognizer(lines: ["first", "second"]))
        try await pipeline.run(source: source, sessionID: session)
        let segs = try await store.all(session: session)
        XCTAssertEqual(segs.map(\.text), ["first", "second"])
        XCTAssertEqual(segs[0].t0, 0, accuracy: 0.35)  // pre-roll may start up to 300 ms early
        XCTAssertEqual(segs[1].t0, 2, accuracy: 0.35)
        XCTAssertTrue(segs.allSatisfy { $0.speaker == "unknown" && $0.engine == "scripted" })
    }
}

/// Synthetic capture source: one second per pattern entry, tone (true) or silence (false).
final class ToneSource: CaptureSource, @unchecked Sendable {
    let id = CaptureSourceID.file("tone")
    let frames: AsyncStream<PCMFrame>
    private let continuation: AsyncStream<PCMFrame>.Continuation
    private let pattern: [Bool]
    init(pattern: [Bool]) {
        self.pattern = pattern
        (frames, continuation) = AsyncStream.makeStream()
    }
    func start() async throws {
        var t = 0.0
        for on in pattern {
            for _ in 0..<50 {
                var samples = [Int16](repeating: 0, count: 320)
                if on {
                    for i in 0..<320 {
                        let phase = 2 * Double.pi * 440 * (t + Double(i) / 16_000)
                        samples[i] = Int16(8000 * sin(phase))
                    }
                }
                continuation.yield(PCMFrame(samples: samples, timestamp: t, source: id))
                t += 0.02
            }
        }
        continuation.finish()
    }
    func stop() async { continuation.finish() }
}
