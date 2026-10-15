import XCTest

@testable import EarCore

/// Real models (run `make models` + `make fixtures`). Skipped when models are missing.
/// Thresholds: HANDOVER §11 P2 sherpa rows (Apple +5 points; Apple engine dropped by ADR-008).
final class SileroVADTests: XCTestCase {
    func testUtteranceCountMatchesScriptWithin10Percent() async throws {
        let vad = try loadOrSkip { try SileroVAD() }
        let source = FileCaptureSource(url: try Fixtures.wav("lecture_en_01"), realtime: false)
        try await source.start()
        var starts = 0
        for await f in source.frames { if case .speechStart = vad.process(f) { starts += 1 } }
        let expected = try Fixtures.timeline("lecture_en_01").count
        XCTAssertEqual(
            Double(starts), Double(expected), accuracy: Double(expected) * 0.10, "speech segments vs utterances")
    }

    func testSilenceHasNoSpeechStart() throws {
        let vad = try loadOrSkip { try SileroVAD() }
        for i in 0..<500 {
            XCTAssertNil(
                vad.process(
                    PCMFrame(samples: Array(repeating: 0, count: 320), timestamp: Double(i) * 0.02, source: .mic)))
        }
    }
}

final class ASRIntegrationTests: XCTestCase {
    static func transcribe(_ name: String) async throws -> (String, [Segment]) {
        let vad = try loadOrSkip { try SileroVAD() }
        let rec = try loadOrSkip { try SherpaStreamingRecognizer(numThreads: 4) }
        let store = try SQLiteTranscriptStore.inMemory()
        let session = try await store.startSession(SessionInfo(captureSource: "file"))
        let pipeline = AmbientPipeline(store: store, vad: vad, recognizer: rec)
        try await pipeline.run(
            source: FileCaptureSource(url: try Fixtures.wav(name), realtime: false), sessionID: session)
        let segs = try await store.all(session: session)
        return (segs.map(\.text).joined(separator: " "), segs)
    }

    private func wer(_ fixture: String, script: String? = nil) async throws -> Double {
        let (hyp, _) = try await Self.transcribe(fixture)
        let w = WER.rate(reference: try Fixtures.script(script ?? fixture), hypothesis: hyp)
        print("WER \(fixture): \(String(format: "%.1f", w * 100)) %")
        return w
    }

    func testCleanLectureWER() async throws {
        let w = try await wer("lecture_en_01")
        XCTAssertLessThanOrEqual(w, 0.15, "sherpa clean ≤ 10 % + 5")
    }

    func testNoisyLectureWER() async throws {
        let w = try await wer("lecture_en_01_snr10", script: "lecture_en_01")
        XCTAssertLessThanOrEqual(w, 0.30, "sherpa 10 dB ≤ 25 % + 5")
    }

    func testLibriSpeechSampleWER() async throws {
        struct Ref: Decodable {
            let id: String
            let text: String
            let wav: String
        }
        let dir = Fixtures.root.appendingPathComponent("librispeech_sample")
        let refs = try JSONDecoder().decode([Ref].self, from: Data(contentsOf: dir.appendingPathComponent("refs.json")))
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(refs[0].wav).path) else {
            throw XCTSkip("LibriSpeech WAVs missing — run make fixtures")
        }
        let rec = try loadOrSkip { try SherpaStreamingRecognizer(numThreads: 4) }
        var refWords = ""
        var hypWords = ""
        for r in refs {  // whole utterance, no VAD: LibriSpeech clips are single utterances
            let source = FileCaptureSource(url: dir.appendingPathComponent(r.wav), realtime: false)
            try await source.start()
            for await f in source.frames { rec.feed(f) }
            await rec.finishUtterance()
            refWords += " " + r.text
        }
        await rec.stop()
        for await res in rec.results where res.isFinal { hypWords += " " + res.text }
        let w = WER.rate(reference: refWords, hypothesis: hypWords)
        print("WER librispeech_sample: \(String(format: "%.1f", w * 100)) %")
        XCTAssertLessThanOrEqual(w, 0.17, "sherpa ≤ 12 % + 5 (A1)")
    }
}

func loadOrSkip<T>(_ make: () throws -> T) throws -> T {
    do { return try make() } catch EarError.notFound(let what) { throw XCTSkip("missing \(what)") }
}
