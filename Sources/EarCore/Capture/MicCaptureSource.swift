@preconcurrency import AVFoundation
import Foundation

/// Live microphone (built-in or Bluetooth HFP, whatever the session routes) → 20 ms 16 kHz frames (P1.2).
/// Survives sample-rate changes on route switches by re-creating the tap and converter.
/// Never writes audio to disk (§10.1).
public final class MicCaptureSource: CaptureSource, @unchecked Sendable {
    public let id: CaptureSourceID
    public let frames: AsyncStream<PCMFrame>
    private let continuation: AsyncStream<PCMFrame>.Continuation
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var state = State()  // guarded by lock (holds non-Sendable converter)
    private var observer: NSObjectProtocol?

    struct State {
        var chunker = FrameChunker(source: .mic)
        var converter: PCMConverter?
        var startedAt: ContinuousClock.Instant?
        var inputSampleRate: Double = 0
    }

    public struct Stats: Sendable {
        public var framesEmitted: Int
        public var droppedFrames: Int
        public var inputSampleRate: Double
        public static let zero = Stats(framesEmitted: 0, droppedFrames: 0, inputSampleRate: 0)
        public init(framesEmitted: Int, droppedFrames: Int, inputSampleRate: Double) {
            (self.framesEmitted, self.droppedFrames, self.inputSampleRate) = (
                framesEmitted, droppedFrames, inputSampleRate
            )
        }
    }

    public init(id: CaptureSourceID = .mic) {
        self.id = id
        (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(500))
        state.chunker = FrameChunker(source: id)
    }

    public func start() async throws {
        try installTap()
        engine.prepare()
        try engine.start()
        lock.withLock { state.startedAt = ContinuousClock.now }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.restartAfterRouteChange() }
    }

    public func stop() async {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation.finish()
    }

    /// Frames emitted vs. frames expected from wall-clock time since start.
    public func stats() -> Stats {
        lock.withLock {
            let s = state
            let emitted = s.chunker.emittedSamples / PCMFrame.standardLength
            let elapsed = s.startedAt.map { LatencyTrace.seconds($0.duration(to: .now)) } ?? 0
            let expected = Int(elapsed * 50)
            return Stats(
                framesEmitted: emitted, droppedFrames: max(0, expected - emitted - 10),
                inputSampleRate: s.inputSampleRate)
        }
    }

    private func installTap() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw EarError.audio("no input device") }
        let converter = try PCMConverter(inputFormat: format)
        lock.withLock {
            state.converter = converter
            state.inputSampleRate = format.sampleRate
        }
        let continuation = continuation
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [unowned self] buffer, _ in
            let frames = lock.withLock { () -> [PCMFrame] in
                guard let samples = try? state.converter?.convert(buffer) else { return [] }
                return state.chunker.push(samples)
            }
            for f in frames { continuation.yield(f) }
        }
    }

    private func restartAfterRouteChange() {
        engine.inputNode.removeTap(onBus: 0)
        do {
            try installTap()
            engine.prepare()
            try engine.start()
        } catch {
            continuation.finish()  // the pipeline surfaces this as SessionHealth.ended
        }
    }
}
