import Foundation

/// Where a frame came from. `description` is what lands in `audio_segments.source` (§6).
public enum CaptureSourceID: Sendable, Hashable, Codable, CustomStringConvertible {
    case mic, bluetoothHFP
    case file(String)
    case omiBLE(String)
    case remote

    public var description: String {
        switch self {
        case .mic: "mic"
        case .bluetoothHFP: "bluetoothHFP"
        case .file(let name): "file:\(name)"
        case .omiBLE(let id): "omiBLE:\(id)"
        case .remote: "remote"
        }
    }
}

/// 20 ms of 16 kHz mono Int16 audio (§5).
public struct PCMFrame: Sendable {
    public var samples: [Int16]
    public let sampleRate: Int
    public let timestamp: TimeInterval  // seconds on the pipeline clock, start of this frame
    public let source: CaptureSourceID

    public init(samples: [Int16], sampleRate: Int = 16_000, timestamp: TimeInterval, source: CaptureSourceID) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.timestamp = timestamp
        self.source = source
    }

    public static let standardLength = 320

    /// Root-mean-square level in 0…1, for meters and energy VAD.
    public var rms: Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + Float($1) * Float($1) }
        return (sum / Float(samples.count)).squareRoot() / 32768
    }
}

public protocol CaptureSource: AnyObject, Sendable {
    var id: CaptureSourceID { get }
    var frames: AsyncStream<PCMFrame> { get }
    func start() async throws
    func stop() async
}

/// Cuts an arbitrary sample stream into fixed 20 ms frames with sample-accurate timestamps.
struct FrameChunker {
    private var pending: [Int16] = []
    private(set) var emittedSamples = 0
    let origin: TimeInterval
    let source: CaptureSourceID

    init(origin: TimeInterval = 0, source: CaptureSourceID) {
        self.origin = origin
        self.source = source
    }

    mutating func push(_ samples: [Int16]) -> [PCMFrame] {
        pending += samples
        var out: [PCMFrame] = []
        let n = PCMFrame.standardLength
        while pending.count >= n {
            let t = origin + Double(emittedSamples) / 16_000
            out.append(PCMFrame(samples: Array(pending.prefix(n)), timestamp: t, source: source))
            pending.removeFirst(n)
            emittedSamples += n
        }
        return out
    }
}
