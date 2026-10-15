import XCTest

@testable import EarCore

/// P5 simulator smoke test: EarSim → earbridge on the Mac (localhost), Mac tier forced. A recorded question goes
/// through the push-to-talk path, the Mac answers and speaks. Run with `make remote-smoke` (starts earbridge).
final class RemoteLoopSmokeTest: XCTestCase {
    func testMacTierLoopFromSimulator() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["EARBRIDGE_PORT"].flatMap(Int.init), let token = env["EARBRIDGE_TOKEN"],
            let dir = env["CLIPIR_EAR_FIXTURES"]
        else { throw XCTSkip("run via make remote-smoke") }
        let ledger = ConnectionLedger()
        let bridge = BridgeClient(
            pairing: PairingInfo(host: "127.0.0.1", port: port, token: token), egress: EgressGuard(ledger: ledger))
        let events = await bridge.subscribe()
        await bridge.start()
        for await e in events { if case .connected = e { break } }
        let store = try SQLiteTranscriptStore.inMemory()
        let session = try await store.startSession(SessionInfo(captureSource: "t", deviceModel: "EarSim"))
        _ = try await store.append(
            Segment(
                sessionID: session, t0: 70, t1: 77,
                text: "For the optimiser we use Adam because it is forgiving", source: "t", engine: "t"))
        var config = PipelineConfig()
        config.policy = TierPolicy(mode: .mac)
        let p = EarPipeline(
            config: config,
            deps: PipelineDeps(
                store: store, makeSource: { throw EarError.cancelled }, makeVAD: { EnergyVAD() },
                makeRecognizer: { try SherpaStreamingRecognizer() }, answerer: MockAnswerer(),
                output: try AudioOutput(sampleRate: 24_000, silent: true), bridge: bridge))
        await p.beginQuery()
        try await p.feedQuestionAudio(url: URL(fileURLWithPath: dir + "/queries/lecture_en_01_q03.wav"), realtime: true)
        let h = try await p.endQuery()
        var tiers: [String] = []
        var text = ""
        for await e in h.events {
            if case .tier(let t) = e { tiers.append(t) }
            if case .token(let t) = e { text += t }
        }
        try await Task.sleep(for: .milliseconds(300))
        let q = try await store.queries().last!
        print("RemoteLoopSmokeTest: \(q.question) → \(q.answer) | \(q.latencyJSON)")
        XCTAssertEqual(tiers, ["mac"])
        XCTAssertTrue(text.lowercased().contains("adam"), text)
        XCTAssertEqual(Set(ledger.all().map(\.host)), ["127.0.0.1"])
        await bridge.stop()
    }
}
