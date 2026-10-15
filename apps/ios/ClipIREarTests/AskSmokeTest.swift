import XCTest

@testable import EarCore

/// P3 simulator smoke test: ambient transcript of lecture_en_01, then a recorded question through the same ASR path
/// to the TinyAnswerer (Qwen3-0.6B, CPU in the simulator); end-to-end < 15 s and the answer contains the fact.
final class AskSmokeTest: XCTestCase {
    func testScriptedQuestionEndToEnd() async throws {
        guard let dir = ProcessInfo.processInfo.environment["CLIPIR_EAR_FIXTURES"] else {
            throw XCTSkip("no fixtures env")
        }
        let fixtures = URL(fileURLWithPath: dir)
        let store = try SQLiteTranscriptStore.inMemory()
        let deps = PipelineDeps(
            store: store,
            makeSource: {
                FileCaptureSource(url: fixtures.appendingPathComponent("lecture_en_01.wav"), realtime: false)
            },
            makeVAD: { try SileroVAD() }, makeRecognizer: { try SherpaStreamingRecognizer() },
            answerer: try LlamaAnswerer.tiny())
        let p = EarPipeline(config: PipelineConfig(), deps: deps)
        try await p.startAmbient()
        await p.waitUntilAmbientEnds()
        // Q1 asks about the assignment deadline (Friday); the whole lecture is in the store, so ask "at" its time.
        let start = Date()
        struct Fact: Decodable { let t: Double }
        let t = try JSONDecoder().decode(
            [Fact].self, from: Data(contentsOf: fixtures.appendingPathComponent("lecture_en_01.facts.json")))[0].t
        let h = try await p.askFromAudio(
            url: fixtures.appendingPathComponent("queries/lecture_en_01_q01.wav"), at: t + 5)
        var text = ""
        for await e in h.events { if case .token(let t) = e { text += t } }
        let seconds = Date().timeIntervalSince(start)
        print(
            "AskSmokeTest: \"\(h.question)\" → \"\(text.prefix(120).replacingOccurrences(of: "\n", with: " "))\" in \(String(format: "%.1f", seconds)) s; trace \(h.trace.json())"
        )
        XCTAssertEqual(h.intent, .explainLast)
        XCTAssertLessThan(seconds, 15)
        XCTAssertTrue(text.lowercased().contains("friday"), text)
    }
}
