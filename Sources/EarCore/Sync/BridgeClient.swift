import Foundation
import Synchronization

/// WebSocket client for earbridge (P5.5): hello/welcome, control + binary frames, RTT pings every 5 s,
/// reconnect with backoff. Every connection goes through EgressGuard with the paired Mac allowed (§2.5).
public actor BridgeClient {
    public enum Event: Sendable {
        case connected(server: String)
        case disconnected(reason: String)
        case message([String: SendableJSON])
        case audio(seq: UInt32, samples: [Int16])
        case rtt(TimeInterval)
    }

    public let pairing: PairingInfo
    private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]
    private let egress: EgressGuard
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var loops: [Task<Void, Never>] = []
    private var seq: UInt32 = 0
    public private(set) var isConnected = false
    public private(set) var rtt: TimeInterval?
    private var stopped = false

    public init(pairing: PairingInfo, egress: EgressGuard = .shared) {
        self.pairing = pairing
        self.egress = egress
        egress.setPairedMac(host: pairing.host)
    }

    /// Every subscriber gets every event (recognizer, query path and UI all listen).
    public func subscribe() -> AsyncStream<Event> {
        let (stream, c) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        let id = UUID()
        subscribers[id] = c
        c.onTermination = { _ in Task { await self.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    private func emit(_ e: Event) { for c in subscribers.values { c.yield(e) } }

    /// Connects (and keeps reconnecting with backoff until `stop()`).
    public func start() {
        stopped = false
        loops.append(Task { await self.connectLoop() })
    }

    public func stop() {
        stopped = true
        task?.cancel(with: .goingAway, reason: nil)
        for l in loops { l.cancel() }
        loops = []
        isConnected = false
    }

    private func connectLoop() async {
        var backoff = 0.5
        while !stopped && !Task.isCancelled {
            do {
                try await connectOnce()
                backoff = 0.5
                await receiveLoop()
            } catch {
                emit(.disconnected(reason: "\(error)"))
            }
            isConnected = false
            if stopped { return }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 10)
        }
    }

    private func connectOnce() async throws {
        let session = try egress.session(for: pairing.url, pin: pairing.fp == "none" ? nil : pairing.fp)
        let t = session.webSocketTask(with: pairing.url)
        t.maximumMessageSize = 4 << 20
        t.resume()
        (self.session, task) = (session, t)
        try await t.send(
            .string(
                ProtocolCodec.encode(
                    "hello",
                    [
                        "token": pairing.token, "caps": ["pcm_in": 16_000],
                        "client": ["app": "ClipIREar", "version": EarCore.version, "device": "iPhone", "os": "iOS"],
                    ])))
        guard case .string(let s) = try await t.receive(), let m = ProtocolCodec.decode(s),
            m["t"] as? String == "welcome"
        else {
            throw EarError.notFound("no welcome (check the pairing code)")
        }
        isConnected = true
        let server = ((m["server"] as? [String: Any])?["models"] as? [String: Any])?["llm"] as? String ?? "earbridge"
        emit(.connected(server: server))
        loops.append(Task { await self.pingLoop() })
    }

    private func receiveLoop() async {
        guard let t = task else { return }
        while !Task.isCancelled {
            do {
                switch try await t.receive() {
                case .string(let s):
                    guard let m = ProtocolCodec.decode(s) else { continue }
                    if m["t"] as? String == "pong", let ts = m["ts"] as? Double {
                        rtt = Date().timeIntervalSince1970 - ts
                        emit(.rtt(rtt!))
                    } else {
                        emit(.message(SendableJSON.wrap(m)))
                    }
                case .data(let d):
                    if let f = ProtocolCodec.parseBinary(d), f.kind == ProtocolCodec.Kind.ttsPCM.rawValue {
                        emit(.audio(seq: f.seq, samples: ProtocolCodec.samples(f.payload)))
                    }
                @unknown default: break
                }
            } catch {
                emit(
                    .disconnected(
                        reason: t.closeCode.rawValue == ProtocolCodec.closeBadToken ? "bad token" : "\(error)"))
                return
            }
        }
    }

    private func pingLoop() async {
        while !Task.isCancelled && isConnected {
            send("ping", ["ts": Date().timeIntervalSince1970])
            try? await Task.sleep(for: .seconds(5))
        }
    }

    public func send(_ type: String, _ fields: [String: Any] = [:]) {
        task?.send(.string(ProtocolCodec.encode(type, fields))) { _ in }
    }

    public func sendPCM(_ samples: [Int16]) {
        seq &+= 1
        task?.send(.data(ProtocolCodec.binary(.pcmIn, seq: seq, payload: ProtocolCodec.pcm16(samples)))) { _ in }
    }
}

/// JSON values that cross actor boundaries (control messages are small).
public enum SendableJSON: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([SendableJSON])
    case object([String: SendableJSON])
    case null

    static func wrap(_ any: Any) -> SendableJSON {
        switch any {
        case let s as String: .string(s)
        case let b as Bool: .bool(b)
        case let n as NSNumber: .number(n.doubleValue)
        case let a as [Any]: .array(a.map(wrap))
        case let o as [String: Any]: .object(o.mapValues(wrap))
        default: .null
        }
    }

    static func wrap(_ o: [String: Any]) -> [String: SendableJSON] { o.mapValues(wrap) }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var number: Double? { if case .number(let n) = self { n } else { nil } }
    public var object: [String: SendableJSON]? { if case .object(let o) = self { o } else { nil } }
    public var array: [SendableJSON]? { if case .array(let a) = self { a } else { nil } }
}
