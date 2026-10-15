import Foundation
import Synchronization

public enum Stage: String, Codable, CaseIterable, Sendable {
    case pttDown, speechEnd, earcon, asrFinal, contextReady, llmFirstToken, llmFirstSentence, ttsFirstAudio,
        audioOutStart,
        audioOutEnd, done
}

/// Monotonic stage marks, exported as seconds since `pttDown` (§9). First mark of a stage wins.
public final class LatencyTrace: Sendable {
    private let clock = ContinuousClock()
    private let marks = Mutex<[Stage: ContinuousClock.Instant]>([:])

    public init() {}

    public func mark(_ s: Stage) {
        let now = clock.now
        marks.withLock { if $0[s] == nil { $0[s] = now } }
    }

    public func export() -> [Stage: TimeInterval] {
        marks.withLock { m in
            guard let origin = m[.pttDown] ?? m.values.min() else { return [:] }
            return m.mapValues { Self.seconds(origin.duration(to: $0)) }
        }
    }

    public func json(extras: [String: Any] = [:]) -> String {
        var dict: [String: Any] = Dictionary(
            uniqueKeysWithValues: export().map { ($0.key.rawValue, ($0.value * 1000).rounded() / 1000) })
        dict.merge(extras) { a, _ in a }
        let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func seconds(_ d: Duration) -> TimeInterval {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
