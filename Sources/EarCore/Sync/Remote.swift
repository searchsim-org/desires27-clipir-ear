import Foundation
import Synchronization

/// Which tier answers (P5.6): `auto` uses the Mac when connected and RTT < 150 ms; falls back on a 3 s timeout.
public struct TierPolicy: Sendable, Equatable {
    public enum Mode: String, Sendable, CaseIterable, Codable { case auto, phone, mac }
    public var mode: Mode
    public var rttThreshold: TimeInterval = 0.150
    public var fallbackTimeout: TimeInterval = 3.0

    public init(mode: Mode = .auto) { self.mode = mode }

    public func choose(connected: Bool, rtt: TimeInterval?) -> Tier {
        switch mode {
        case .phone: .phone
        case .mac: connected ? .mac : .phone  // no Mac: the phone answers rather than nobody
        case .auto: connected && (rtt ?? .infinity) < rttThreshold ? .mac : .phone
        }
    }
}

/// Forwards PCM to the Mac and surfaces its ambient `asr.*` messages as ASRResults (P5.6). The Mac does its own
/// endpointing, so `finishUtterance` is a no-op; `stop` ends the session and the Mac answers with `segments.sync`.
public final class RemoteRecognizer: StreamingRecognizer, @unchecked Sendable {
    public let results: AsyncStream<ASRResult>
    private let continuation: AsyncStream<ASRResult>.Continuation
    private let bridge: BridgeClient
    private let sessionID: String
    private let outbox: AsyncStream<[Int16]>.Continuation
    private var tasks: [Task<Void, Never>] = []

    public init(bridge: BridgeClient, sessionID: String) {
        self.bridge = bridge
        self.sessionID = sessionID
        (results, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        let (pcm, outbox) = AsyncStream.makeStream(of: [Int16].self, bufferingPolicy: .unbounded)
        self.outbox = outbox
        tasks.append(Task { for await samples in pcm { await bridge.sendPCM(samples) } })  // keeps frame order
    }

    public func start(locale: Locale) async throws {
        let (c, session) = (continuation, sessionID)
        let events = await bridge.subscribe()
        tasks.append(
            Task {
                for await e in events {
                    guard case .message(let m) = e, m["query_id"] == nil, let t = m["t"]?.string else { continue }
                    if t == "asr.partial" || t == "asr.final", let text = m["text"]?.string {
                        c.yield(
                            ASRResult(
                                text: text, isFinal: t == "asr.final", t0: m["t0"]?.number ?? 0,
                                t1: m["t1"]?.number ?? 0, engine: "remote:sherpa"))
                    } else if t == "segments.sync" {
                        c.finish()
                    }
                }
            })
        await bridge.send("session.start", ["session_id": session, "locale": locale.identifier, "mode": "ambient"])
    }

    public func feed(_ frame: PCMFrame) { outbox.yield(frame.samples) }
    public func finishUtterance() async {}

    public func stop() async {
        outbox.finish()
        await bridge.send("session.stop", ["session_id": sessionID])
    }
}
