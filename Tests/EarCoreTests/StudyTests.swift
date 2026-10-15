import AVFoundation
import GRDB
import XCTest

@testable import EarCore

/// Phase 8: cue rate limit (P8.6), Record (P8.3), MetricKit intake (P8.5).
final class StudyTests: XCTestCase {
    func testCueRateLimitSixPerHourOncePerKeyword() {
        var e = CueEngine()
        let keywords = CueEngine.keywords(from: [
            "Ask about the deadline", "budget review", "Adam optimizer",
            "Friday slides", "dataset license", "poster printing",
        ])
        XCTAssertFalse(keywords.contains("about"), "stop-list")
        let lines = [
            "the deadline moved", "deadline again", "the budget is tight", "we use adam? no, optimizer",
            "slides by friday", "the dataset is big", "license terms", "poster printing room",
        ]
        let fired = lines.enumerated().compactMap { i, l in e.cue(for: l, keywords: keywords, at: Double(i) * 60) }
        XCTAssertEqual(fired.count, 6, "\(fired)")
        XCTAssertEqual(fired.first, "Heads up: deadline.")
        XCTAssertEqual(fired.filter { $0.contains("deadline") }.count, 1, "one cue per keyword per hour")
        XCTAssertNil(e.cue(for: "poster printing", keywords: keywords, at: 3000), "seventh within the hour")
        XCTAssertNotNil(e.cue(for: "the deadline", keywords: keywords, at: 3700), "window slides after an hour")
        XCTAssertNil(e.cue(for: "nothing relevant here", keywords: keywords, at: 9000))
    }

    func testRecorderWritesWavAndMarksCoveredSegments() async throws {
        let store = try SQLiteTranscriptStore.inMemory()
        let session = try await store.startSession(SessionInfo(captureSource: "test"))
        for t in [0.0, 10, 30] {
            _ = try await store.append(
                Segment(sessionID: session, t0: t, t1: t + 2, text: "s\(t)", source: "test", engine: "x"))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID()).wav")
        let r = try Recorder(url: url)
        for i in 0..<50 {  // 1 s of 20 ms frames starting at t = 9.5
            r.write(
                PCMFrame(
                    samples: [Int16](repeating: 100, count: 320), timestamp: 9.5 + Double(i) * 0.02,
                    source: .file("test")))
        }
        let span = try XCTUnwrap(r.finish())
        XCTAssertEqual(span.0, 9.5, accuracy: 1e-9)
        XCTAssertEqual(span.1, 10.5, accuracy: 1e-9)
        let f = try AVAudioFile(forReading: url)
        XCTAssertEqual(f.length, 16_000)
        XCTAssertEqual(f.fileFormat.sampleRate, 16_000)
        try await store.markAudioRetained(session: session, from: span.0, to: span.1)
        let retained: [Double] = try await store.db.read {
            try Double.fetchAll($0, sql: "SELECT t0 FROM audio_segments WHERE audio_retained = 1")
        }
        XCTAssertEqual(retained, [10])
        try? FileManager.default.removeItem(at: url)
    }

    func testMetricsIntakeStoresRows() async throws {
        let store = try SQLiteTranscriptStore.inMemory()
        let m = MetricsIntake(store: store)
        try await m.record(
            kind: "metrics", cpuSeconds: 12.5, peakMemoryMB: 900, hangs: 0, crashes: 0, json: Data("{}".utf8))
        try await m.record(
            kind: "diagnostics", cpuSeconds: nil, peakMemoryMB: nil, hangs: 2, crashes: 1, json: Data("{}".utf8))
        let n = try await store.db.read { try Int.fetchOne($0, sql: "SELECT sum(hangs) FROM device_metrics") }
        XCTAssertEqual(n, 2)
    }
}

final class StudyPipelineTests: XCTestCase {
    /// Record captures exactly the ambient frames; a final that names a note keyword earns one logged cue.
    func testRecordAndCueThroughThePipeline() async throws {
        let store = try SQLiteTranscriptStore.inMemory()
        try await store.addNote("ask about the deadline")
        let wav = try TestAudio.writeWav(seconds: 2)
        let p = EarPipeline(
            config: PipelineConfig(),
            deps: PipelineDeps(
                store: store, makeSource: { FileCaptureSource(url: wav, realtime: false) },
                makeVAD: { EnergyVAD() },
                makeRecognizer: { ScriptedRecognizer(lines: ["the deadline moved to friday"]) },
                answerer: MockAnswerer { _ in "" }))
        await p.setCues(enabled: true)
        let rec = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID()).wav")
        try await p.startRecording(to: rec)
        try await p.startAmbient()
        await p.waitUntilAmbientEnds()
        let url = await p.stopRecording()
        XCTAssertEqual(url, rec)
        let f = try AVAudioFile(forReading: rec)
        XCTAssertEqual(Double(f.length) / 16_000, 2, accuracy: 0.05, "2 s of ambient audio recorded")
        let retained = try await store.db.read {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM audio_segments WHERE audio_retained = 1")
        }
        XCTAssertEqual(retained, 1)
        let cues = try await store.queries().filter { $0.intent == "cue" }
        XCTAssertEqual(cues.map(\.answer), ["Heads up: deadline."])
        try? FileManager.default.removeItem(at: rec)
    }
}
