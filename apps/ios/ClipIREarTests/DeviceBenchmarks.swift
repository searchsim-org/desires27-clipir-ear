import EarTTSKokoro
import XCTest

@testable import EarCore

/// Device benchmarks (HANDOVER §12). Run on a signed device build only (ADR-010):
///   xcodebuild test -scheme ClipIREar -destination 'id=<UDID>' -only-testing:ClipIREarTests/LLMBench
/// Models come from the app's Documents/models (Finder sideload, §13); results are attached as JSON.
class DeviceBenchmark: XCTestCase {
    override func setUpWithError() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("device benchmark: run on a physical iPhone (ADR-010)")
        #endif
    }

    func attach(_ name: String, _ object: Any) throws {
        let a = XCTAttachment(
            data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]),
            uniformTypeIdentifier: "public.json")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    static func pct(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted()
        return s[min(s.count - 1, Int((p * Double(s.count - 1)).rounded()))]
    }
}

/// P3: Gemma 4 E2B, 20 prompts of ≈ 1,500 tokens → TTFT p50/p95 and decode tok/s (warm). Asserts TTFT ≤ 1.5 s and
/// ≥ 15 tok/s (A17-class targets; the 13 Pro Max result decides ADR-014).
final class LLMBench: DeviceBenchmark {
    func testTTFTAndDecodeSpeed() throws {
        let engine = try LlamaEngine(path: try Models.path(Models.gemma4E2B))
        let filler = String(
            repeating: "The speaker explained how the bridge deck was strengthened with steel cables. ", count: 90)
        var ttft: [Double] = []
        var tps: [Double] = []
        for i in 0..<21 {
            let prompt = engine.chatPrompt(
                system: "Answer briefly.", user: "TRANSCRIPT:\n\(filler)\nQUESTION (\(i)): what was strengthened?")
            let start = Date()
            var first: Date?
            let (_, n) = try engine.generate(prompt: prompt, maxTokens: 64) { _ in
                if first == nil { first = Date() }
                return true
            }
            guard i > 0, let first else { continue }  // first run warms the model
            ttft.append(first.timeIntervalSince(start))
            tps.append(Double(max(1, n - 1)) / max(0.001, Date().timeIntervalSince(first)))
        }
        let result: [String: Any] = [
            "model": engine.modelName, "ttft_p50": Self.pct(ttft, 0.5), "ttft_p95": Self.pct(ttft, 0.95),
            "decode_tps_p50": Self.pct(tps, 0.5), "thermal": DeviceTelemetry.thermalState,
            "footprint_mb": DeviceTelemetry.footprintMB,
        ]
        try attach("LLMBench", result)
        XCTAssertLessThanOrEqual(Self.pct(ttft, 0.5), 1.5)
        XCTAssertGreaterThanOrEqual(Self.pct(tps, 0.5), 15)
    }
}

/// P4.7: lecture_en_01 in real time through the full pipeline with real models; its 10 recorded questions are asked
/// 5 s after each fact. Writes every stage time per query. Targets: earcon ≤ 0.5 s, first audio p50 ≤ 2.5 s.
class LoopBench: DeviceBenchmark {
    /// The answer voice under test; KokoroLoopBench overrides it.
    func makeSpeaker() async throws -> Speaker { SystemSpeaker() }
    var benchName: String { "LoopBench" }
    func checkSpeaker(_ speaker: Speaker) {}

    func testRealtimeLoop() async throws {
        let bundle = Bundle(for: Self.self)
        let wav = try XCTUnwrap(
            bundle.url(forResource: "lecture_en_01", withExtension: "wav", subdirectory: "BenchFixtures"))
        struct Q: Decodable {
            let t: Double
            let wav: String
        }
        let queries = try JSONDecoder().decode(
            [Q].self,
            from: Data(
                contentsOf: try XCTUnwrap(
                    bundle.url(
                        forResource: "lecture_en_01.queries", withExtension: "json", subdirectory: "BenchFixtures"))))
        let store = try SQLiteTranscriptStore.inMemory()
        let llm = LlamaAnswerer(modelPath: try Models.path(Models.gemma4E2B))
        let speaker = try await makeSpeaker()
        let p = EarPipeline(
            config: PipelineConfig(),
            deps: PipelineDeps(
                store: store, makeSource: { FileCaptureSource(url: wav, realtime: true) }, makeVAD: { try SileroVAD() },
                makeRecognizer: { try SherpaStreamingRecognizer() }, answerer: llm, speaker: speaker,
                output: try AudioOutput(sampleRate: 24_000)))
        try llm.warm()
        let start = Date()
        try await p.startAmbient()
        var rows: [[String: Any]] = []
        for q in queries {
            let wait = q.t + 5 - Date().timeIntervalSince(start)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            let h = try await p.askFromAudio(
                url: try XCTUnwrap(
                    bundle.url(
                        forResource: (q.wav as NSString).deletingPathExtension,
                        withExtension: "wav", subdirectory: "BenchFixtures")))
            for await _ in h.events {}
            try await Task.sleep(for: .milliseconds(200))
            rows.append(
                try JSONSerialization.jsonObject(with: Data(try await store.queries().last!.latencyJSON.utf8))
                    as! [String: Any])
        }
        await p.stopAmbient()
        try attach(benchName, rows)
        checkSpeaker(speaker)
        let firstAudio = rows.compactMap { r in
            (r["audioOutStart"] as? Double).map { $0 - (r["speechEnd"] as? Double ?? 0) }
        }
        let earcon = rows.compactMap { r in (r["earcon"] as? Double).map { $0 - (r["speechEnd"] as? Double ?? 0) } }
        XCTAssertLessThanOrEqual(Self.pct(firstAudio, 0.5), 2.5)
        XCTAssertLessThanOrEqual(earcon.max() ?? 9, 0.5)
        XCTAssertFalse(rows.contains { $0["thermal_state"] as? String == "critical" })
    }
}

/// ADR-020 go/no-go (device check): the LoopBench scenario with Kokoro (af_heart) answering and the Apple voice
/// as fallback, Gemma loaded. Same targets (first audio p50 ≤ 2.5 s); the per-query rows carry memory_footprint_mb,
/// Kokoro must still be speaking at the end and must have spoken at least 9 in 10 sentences.
final class KokoroLoopBench: LoopBench {
    override var benchName: String { "KokoroLoopBench" }

    override func makeSpeaker() async throws -> Speaker {
        let kokoro = try KokoroSpeaker(voice: KokoroSpeaker.defaultVoice)
        _ = try await kokoro.render("Ready.")  // first call compiles shaders; measure after it, as the app warms up
        return FallbackSpeaker(primary: kokoro, fallback: SystemSpeaker())
    }

    override func checkSpeaker(_ speaker: Speaker) {
        guard let s = speaker as? FallbackSpeaker else { return XCTFail("not a FallbackSpeaker") }
        let total = s.spokenByPrimary + s.spokenByFallback
        print("KokoroLoopBench: Kokoro spoke \(s.spokenByPrimary) of \(total) sentences")
        XCTAssertTrue(s.primaryHealthy, "Kokoro was switched off during the run")
        XCTAssertGreaterThanOrEqual(s.spokenByPrimary * 10, total * 9, "Kokoro spoke under 9 in 10 sentences")
    }
}
