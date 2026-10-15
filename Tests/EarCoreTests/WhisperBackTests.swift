import XCTest

@testable import EarCore

final class SystemSpeakerTests: XCTestCase {
    func testHelloProducesAudioWithinOneSecondAtAConsistentRate() async throws {
        let speaker = SystemSpeaker()
        let (sentences, c) = AsyncStream.makeStream(of: String.self)
        let start = Date()
        c.yield("hello")
        c.finish()
        var first: TimeInterval?
        var rates = Set<Int>()
        var samples = 0
        for await chunk in speaker.speak(sentences: sentences) {
            if first == nil { first = Date().timeIntervalSince(start) }
            rates.insert(chunk.sampleRate)
            samples += chunk.samples.count
        }
        let firstAudio = try XCTUnwrap(first)
        XCTAssertLessThan(firstAudio, 1.0)
        XCTAssertEqual(rates.count, 1)
        XCTAssertGreaterThan(samples, rates.first! / 10)  // at least 100 ms of audio
    }
}

final class LoopTests: XCTestCase {
    /// Scripted question → earcon, spoken answer, every latency mark present and in order (P4 loop smoke, macOS).
    func testFullLoopMarksEveryStageInOrder() async throws {
        let store = try SQLiteTranscriptStore.inMemory()
        let session = try await store.startSession(SessionInfo(captureSource: "t"))
        _ = try await store.append(
            Segment(sessionID: session, t0: 0, t1: 3, text: "The deadline moves to Friday", source: "t", engine: "t"))
        let output = try AudioOutput(sampleRate: 24_000, silent: true)
        let p = EarPipeline(
            config: PipelineConfig(),
            deps: PipelineDeps(
                store: store, makeSource: { throw EarError.cancelled }, makeVAD: { EnergyVAD() },
                makeRecognizer: { ScriptedRecognizer(lines: ["What did the speaker just say"]) },
                answerer: MockAnswerer { _ in "The speaker said the deadline moves to Friday.\nSOURCE: transcript" },
                speaker: SystemSpeaker(), output: output))
        // a tone stands in for the question audio
        let h = try await p.askFromAudio(url: try TestAudio.writeWav(seconds: 1))
        for await _ in h.events {}
        try await Task.sleep(for: .milliseconds(300))
        let q = try await store.queries().last!
        let latency = try JSONSerialization.jsonObject(with: Data(q.latencyJSON.utf8)) as! [String: Any]
        let order: [Stage] = [
            .pttDown, .speechEnd, .earcon, .asrFinal, .contextReady, .llmFirstToken, .llmFirstSentence,
            .ttsFirstAudio, .audioOutStart, .audioOutEnd, .done,
        ]
        let times = order.map { latency[$0.rawValue] as? Double }
        XCTAssertFalse(times.contains(nil), "missing: \(zip(order, times).filter { $0.1 == nil }.map(\.0))")
        XCTAssertEqual(times.compactMap { $0 }, times.compactMap { $0 }.sorted())
        XCTAssertLessThan(
            (latency["earcon"] as! Double) - (latency["speechEnd"] as! Double), 0.1, "earcon ≤ 100 ms after speechEnd")
        XCTAssertEqual(latency["tts_engine"] as? String, "SystemSpeaker")
    }

    func testRepeatLastAnswerSpeaksWithoutTheModel() async throws {
        let calls = CallCounter()
        let store = try SQLiteTranscriptStore.inMemory()
        _ = try await store.startSession(SessionInfo(captureSource: "t"))
        let output = try AudioOutput(sampleRate: 24_000, silent: true)
        let p = EarPipeline(
            config: PipelineConfig(),
            deps: PipelineDeps(
                store: store, makeSource: { throw EarError.cancelled }, makeVAD: { EnergyVAD() },
                makeRecognizer: { ScriptedRecognizer(lines: []) },
                answerer: MockAnswerer { _ in
                    calls.bump()
                    return "Short answer here for you.\nSOURCE: none"
                },
                speaker: SystemSpeaker(), output: output))
        let h = try await p.ask(question: "anything")
        for await _ in h.events {}
        try await Task.sleep(for: .milliseconds(200))
        await p.repeatLastAnswer()
        XCTAssertEqual(calls.count, 1)
        let last = await p.lastAnswer
        XCTAssertEqual(last, "Short answer here for you.")
    }
}

final class CallCounter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func bump() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}
