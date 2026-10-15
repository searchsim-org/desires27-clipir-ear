import XCTest

@testable import EarCore

/// P4 simulator smoke test: TinyAnswerer + SystemSpeaker on EarSim. A recorded question about a stored transcript
/// produces spoken audio, and every LatencyTrace mark is present and in increasing order.
final class LoopSmokeTest: XCTestCase {
    func testScriptedQuestionIsSpokenWithAllMarks() async throws {
        guard let dir = ProcessInfo.processInfo.environment["CLIPIR_EAR_FIXTURES"] else {
            throw XCTSkip("no fixtures env")
        }
        let fixtures = URL(fileURLWithPath: dir)
        let store = try SQLiteTranscriptStore.inMemory()
        let session = try await store.startSession(SessionInfo(captureSource: "file", deviceModel: "EarSim"))
        _ = try await store.append(
            Segment(
                sessionID: session, t0: 18, t1: 23,
                text: "The deadline for the second assignment moves to Friday the fourteenth",
                source: "file", engine: "t"))
        let p = EarPipeline(
            config: PipelineConfig(),
            deps: PipelineDeps(
                store: store, makeSource: { throw EarError.cancelled }, makeVAD: { try SileroVAD() },
                makeRecognizer: { try SherpaStreamingRecognizer() }, answerer: try LlamaAnswerer.tiny(),
                speaker: SystemSpeaker(), output: try AudioOutput(sampleRate: 24_000, silent: true)))
        let h = try await p.askFromAudio(url: fixtures.appendingPathComponent("queries/lecture_en_01_q01.wav"))
        var sentences: [String] = []
        for await e in h.events { if case .sentence(let s) = e { sentences.append(s) } }
        try await Task.sleep(for: .milliseconds(300))
        let latency =
            try JSONSerialization.jsonObject(with: Data(try await store.queries().last!.latencyJSON.utf8))
            as! [String: Any]
        let order: [Stage] = [
            .pttDown, .speechEnd, .earcon, .asrFinal, .contextReady, .llmFirstToken, .llmFirstSentence,
            .ttsFirstAudio, .audioOutStart, .audioOutEnd, .done,
        ]
        let times = order.map { latency[$0.rawValue] as? Double }
        print("LoopSmokeTest: \(sentences) \(latency)")
        XCTAssertFalse(sentences.isEmpty)
        XCTAssertFalse(times.contains(nil), "missing: \(zip(order, times).filter { $0.1 == nil }.map(\.0))")
        XCTAssertEqual(times.compactMap { $0 }, times.compactMap { $0 }.sorted())
    }
}
