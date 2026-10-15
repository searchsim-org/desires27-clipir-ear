import Foundation
import XCTest

@testable import EarCore

/// Protocol, tier policy and the Mac tier against a real `earbridge serve` (P5 Swift tests).
final class ProtocolCodecTests: XCTestCase {
    /// Every message the phone sends validates against the shared JSON Schema (docs/protocol).
    func testPhoneMessagesMatchSharedSchemas() throws {
        let dir = Fixtures.root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "docs/protocol")
        let seg = Segment(sessionID: "s", t0: 1, t1: 2, text: "hi", source: "t", engine: "t")
        let messages: [(String, [String: Any])] = [
            ("hello", ["token": "ABCD2345", "client": ["app": "ClipIREar"], "caps": ["pcm_in": 16000]]),
            ("session.start", ["session_id": "s", "locale": "en-US", "mode": "ambient"]),
            ("session.stop", ["session_id": "s"]),
            ("query.begin", ["query_id": "q", "session_id": "s"]),
            (
                "query.end",
                ["query_id": "q", "window_seconds": 60, "segments": [ProtocolCodec.segmentJSON(seg)], "notes": ["n"]]
            ),
            ("query.cancel", ["query_id": "q"]), ("ping", ["ts": 1.5]),
        ]
        for (type, fields) in messages {
            let msg = try XCTUnwrap(ProtocolCodec.decode(ProtocolCodec.encode(type, fields)))
            let schema =
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: dir.appendingPathComponent("\(type).schema.json"))) as! [String: Any]
            for key in schema["required"] as! [String] { XCTAssertNotNil(msg[key], "\(type).\(key)") }
            let props = schema["properties"] as! [String: [String: Any]]
            for (key, value) in msg where key != "t" {
                let want = try XCTUnwrap(props[key]?["type"] as? String, "\(type).\(key) not in schema")
                switch want {
                case "string": XCTAssert(value is String, "\(type).\(key)")
                case "number", "integer": XCTAssert(value is NSNumber, "\(type).\(key)")
                case "object": XCTAssert(value is [String: Any], "\(type).\(key)")
                case "array": XCTAssert(value is [Any], "\(type).\(key)")
                default: XCTFail(want)
                }
            }
        }
    }

    func testBinaryFramesRoundTrip() {
        let d = ProtocolCodec.binary(.ttsPCM, seq: 7, payload: ProtocolCodec.pcm16([1, -2, 300]))
        let f = ProtocolCodec.parseBinary(d)!
        XCTAssertEqual(f.kind, 0x02)
        XCTAssertEqual(f.seq, 7)
        XCTAssertEqual(ProtocolCodec.samples(f.payload), [1, -2, 300])
    }

    func testPairingParsing() {
        XCTAssertEqual(
            PairingInfo.fromQR(#"{"host":"192.168.1.5","port":9478,"token":"ABCD2345","fp":"none"}"#)?.token, "ABCD2345"
        )
        XCTAssertEqual(PairingInfo.manual(host: "192.168.1.5:9500", code: "abcd 2345")?.port, 9500)
        XCTAssertNil(PairingInfo.manual(host: "192.168.1.5", code: "short"))
    }
}

final class TierPolicyTests: XCTestCase {
    func testChoice() {
        XCTAssertEqual(TierPolicy(mode: .auto).choose(connected: true, rtt: 0.023), .mac)
        XCTAssertEqual(TierPolicy(mode: .auto).choose(connected: true, rtt: 0.200), .phone)  // RTT gate
        XCTAssertEqual(TierPolicy(mode: .auto).choose(connected: false, rtt: nil), .phone)
        XCTAssertEqual(TierPolicy(mode: .phone).choose(connected: true, rtt: 0.01), .phone)
        XCTAssertEqual(TierPolicy(mode: .mac).choose(connected: false, rtt: nil), .phone)
        XCTAssertEqual(TierPolicy(mode: .auto).fallbackTimeout, 3.0)
    }
}

/// Runs `earbridge serve` on a free port with a fixed token; optional fake/hung Ollama.
final class EarbridgeProcess {
    let port: Int, token = "TESTTOKN"
    private(set) var fp = "none"
    private let process = Process()
    private var hung: Process?

    init(hangLLM: Bool = false, tls: Bool = false) throws {
        port = Int.random(in: 20_000..<40_000)
        let repo = Fixtures.root.deletingLastPathComponent().deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        if hangLLM {  // an IPv4 socket that accepts and never answers: the phone must fall back after 3 s
            let llmPort = port + 1
            let h = Process()
            h.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            h.arguments = [
                "-c",
                "import socket,time\ns=socket.socket(); s.bind(('127.0.0.1', \(llmPort))); s.listen(8)\n"
                    + "conns=[]\nwhile True: conns.append(s.accept())",
            ]
            try h.run()
            Thread.sleep(forTimeInterval: 0.5)
            env["EARBRIDGE_OLLAMA"] = "http://127.0.0.1:\(llmPort)"
            hung = h
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments =
            [
                "uv", "run", "--project", repo.appendingPathComponent("mac/earbridge").path, "earbridge", "serve",
                "--host", "127.0.0.1", "--port", "\(port)", "--token", token, "--no-bonjour", "--db", ":memory:",
            ] + (tls ? [] : ["--no-tls"])
        process.environment = env
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let health = Self.health(port: port, tls: tls) {
                fp = health["fp"] as? String ?? "none"
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw XCTSkip("earbridge did not start (uv / EarCLI release build missing?)")
    }

    var pairing: PairingInfo { PairingInfo(host: "127.0.0.1", port: port, token: token, fp: fp) }

    /// curl -k: the test only reads the advertised fingerprint; the client under test does the pinning.
    private static func health(port: Int, tls: Bool) -> [String: Any]? {
        let curl = Process()
        let out = Pipe()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-sk", "--max-time", "1", "\(tls ? "https" : "http")://127.0.0.1:\(port)/health"]
        curl.standardOutput = out
        guard (try? curl.run()) != nil else { return nil }
        curl.waitUntilExit()
        return try? JSONSerialization.jsonObject(with: out.fileHandleForReading.readDataToEndOfFile()) as? [String: Any]
    }

    deinit {
        process.terminate()
        hung?.terminate()
    }
}

final class BridgeTests: XCTestCase {
    private func connected(_ client: BridgeClient) async throws -> Bool {
        let events = await client.subscribe()
        await client.start()
        let task = Task { () -> Bool in
            for await e in events {
                if case .connected = e { return true }
                if case .disconnected = e { return false }
            }
            return false
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(8))
            task.cancel()
        }
        defer { timeout.cancel() }
        return await task.value
    }

    func testPinnedCertificateConnectsAndWrongPinIsRefused() async throws {
        let server = try EarbridgeProcess(tls: true)
        XCTAssertEqual(server.fp.count, 64)
        XCTAssertTrue(server.pairing.url.absoluteString.hasPrefix("wss://"))
        let good = BridgeClient(pairing: server.pairing, egress: EgressGuard(ledger: ConnectionLedger()))
        let okGood = try await connected(good)
        await good.stop()
        XCTAssertTrue(okGood, "pinned certificate accepted")
        var p = server.pairing
        p.fp = String(repeating: "0", count: 64)
        let bad = BridgeClient(pairing: p, egress: EgressGuard(ledger: ConnectionLedger()))
        let okBad = try await connected(bad)
        await bad.stop()
        XCTAssertFalse(okBad, "a different certificate must be refused")
    }

    func testBadTokenIsRejected() async throws {
        let server = try EarbridgeProcess()
        var p = server.pairing
        p.token = "WRONG123"
        let client = BridgeClient(pairing: p, egress: EgressGuard(ledger: ConnectionLedger()))
        let ok = try await connected(client)
        await client.stop()
        XCTAssertFalse(ok)
    }

    private func pipeline(
        _ server: EarbridgeProcess, ledger: ConnectionLedger,
        makeSource: @escaping @Sendable () throws -> any CaptureSource = { throw EarError.cancelled }
    ) async throws -> (EarPipeline, SQLiteTranscriptStore) {
        let store = try SQLiteTranscriptStore.inMemory()
        let session = try await store.startSession(SessionInfo(captureSource: "t"))
        _ = try await store.append(
            Segment(
                sessionID: session, t0: 70, t1: 77, text: "For the optimiser we use Adam because it is forgiving",
                source: "t", engine: "t"))
        let client = BridgeClient(pairing: server.pairing, egress: EgressGuard(ledger: ledger))
        let isUp = try await connected(client)
        XCTAssertTrue(isUp)
        var config = PipelineConfig()
        config.policy = TierPolicy(mode: .mac)
        let p = EarPipeline(
            config: config,
            deps: PipelineDeps(
                store: store, makeSource: makeSource, makeVAD: { EnergyVAD() },
                makeRecognizer: { try SherpaStreamingRecognizer() },
                answerer: MockAnswerer { _ in "Local fallback answer about the optimiser here.\nSOURCE: transcript" },
                output: try AudioOutput(sampleRate: 24_000, silent: true), bridge: client))
        return (p, store)
    }

    /// Mac tier end to end: question audio streamed to the Mac, answered and spoken there, only localhost contacted.
    func testMacAnswersAndOnlyTheMacIsContacted() async throws {
        _ = try loadOrSkip { try Models.path(Models.Zipformer.encoder) }
        let server = try EarbridgeProcess()
        let ledger = ConnectionLedger()
        let (p, store) = try await pipeline(server, ledger: ledger)
        await p.beginQuery()
        try await p.feedQuestionAudio(url: Fixtures.root.appendingPathComponent("queries/lecture_en_01_q03.wav"))
        let h = try await p.endQuery()
        var tiers: [String] = []
        var text = ""
        for await e in h.events {
            if case .tier(let t) = e { tiers.append(t) }
            if case .token(let t) = e { text += t }
        }
        try await Task.sleep(for: .milliseconds(300))
        let q = try await store.queries().last!
        print("Mac tier: \(q.question) → \(q.answer) \(q.latencyJSON)")
        XCTAssertEqual(tiers, ["mac"])
        XCTAssertEqual(q.tier, "mac")
        XCTAssertTrue(q.model.hasPrefix("mac:"))
        XCTAssertFalse(text.isEmpty)
        XCTAssertEqual(Set(ledger.all().map(\.host)), ["127.0.0.1"], "egress: only the paired Mac")
        XCTAssertTrue(ledger.violations().isEmpty)
    }

    /// The Mac's LLM hangs → no answer.token within 3 s → fallback earcon, phone answers, row marked fallback.
    func testFallbackToPhoneWithinThreeSeconds() async throws {
        _ = try loadOrSkip { try Models.path(Models.Zipformer.encoder) }
        let server = try EarbridgeProcess(hangLLM: true)
        let (p, store) = try await pipeline(server, ledger: ConnectionLedger())
        await p.beginQuery()
        try await p.feedQuestionAudio(url: Fixtures.root.appendingPathComponent("queries/lecture_en_01_q03.wav"))
        let start = Date()
        let h = try await p.endQuery()
        var tiers: [String] = []
        var firstPhoneToken: TimeInterval?
        for await e in h.events {
            if case .tier(let t) = e { tiers.append(t) }
            if case .token = e, tiers.last == "phone", firstPhoneToken == nil {
                firstPhoneToken = Date().timeIntervalSince(start)
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        let q = try await store.queries().last!
        XCTAssertEqual(tiers, ["mac", "phone"])
        XCTAssertEqual(q.tier, "phone")
        XCTAssertTrue(q.latencyJSON.contains("\"fallback\":true"))
        let t = try XCTUnwrap(firstPhoneToken)
        XCTAssertLessThan(t, 4.0, "fallback answer starts within ≈ 3 s")
        XCTAssertGreaterThanOrEqual(t, 2.9)
    }

    /// Spoken commands asked on the Mac tier run on the phone: the Mac's question text goes through the same
    /// command checks as a phone question instead of the Mac's LLM answering "I will stop".
    func testSpokenCommandsOnTheMacTierRunOnThePhone() async throws {
        _ = try loadOrSkip { try Models.path(Models.Zipformer.encoder) }
        let server = try EarbridgeProcess()
        let ambient = try TestAudio.writeWav(seconds: 60)
        let (p, store) = try await pipeline(server, ledger: ConnectionLedger()) {
            FileCaptureSource(url: ambient, realtime: true)
        }
        try await p.startAmbient()
        func command(_ text: String) async throws -> (sentences: [String], tokens: String) {
            await p.beginQuery()
            try await p.feedQuestionAudio(url: try TestAudio.spoken(text))
            let h = try await p.endQuery()
            var (sentences, tokens) = ([String](), "")
            for await e in h.events {
                if case .sentence(let s) = e { sentences.append(s) }
                if case .token(let t) = e { tokens += t }
            }
            return (sentences, tokens)
        }
        let forget = try await command("Forget the last ten minutes.")
        XCTAssertEqual(forget.tokens, "", "the Mac must not answer a command")
        XCTAssertTrue(forget.sentences.first?.hasPrefix("Forgot the last 10 minutes") == true, "\(forget)")
        let stop = try await command("Stop listening.")
        XCTAssertEqual(stop.tokens, "")
        XCTAssertEqual(stop.sentences, ["Stopped listening."])
        let running = await p.isAmbientRunning
        XCTAssertFalse(running, "capture still running after the spoken command")
        let intents = try await store.queries().map(\.intent)
        XCTAssertEqual(intents, ["purge", "command"], "one phone row per command, no Mac row left behind")
    }
}
