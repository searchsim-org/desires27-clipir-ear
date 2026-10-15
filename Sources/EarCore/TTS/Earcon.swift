import Foundation

/// Short non-speech cues (§3.3, P1.4/P4.3), generated in code: two 60 ms sine tones = 120 ms.
public enum Earcon: Sendable {
    case listening  // rising: question heard, answer coming
    case fallback  // falling: Mac unreachable / error, answering on the phone

    public func chunk(sampleRate: Int = 24_000) -> AudioChunk {
        let (f1, f2): (Double, Double) = self == .listening ? (880, 1320) : (660, 440)
        return AudioChunk(samples: Self.tone(f1, sampleRate) + Self.tone(f2, sampleRate), sampleRate: sampleRate)
    }

    static func tone(_ hz: Double, _ sr: Int, seconds: Double = 0.06, amplitude: Double = 0.25) -> [Int16] {
        let n = Int(seconds * Double(sr))
        let fade = Int(0.005 * Double(sr))  // 5 ms ramps avoid clicks
        return (0..<n).map { i in
            let env = min(1, Double(min(i, n - 1 - i)) / Double(fade))
            return Int16(32767 * amplitude * env * sin(2 * .pi * hz * Double(i) / Double(sr)))
        }
    }
}
