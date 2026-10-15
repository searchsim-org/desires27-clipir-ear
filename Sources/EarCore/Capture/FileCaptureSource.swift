@preconcurrency import AVFoundation
import Foundation

/// Reads a sound file (any rate/channels), emits 20 ms frames: paced to real time for latency tests,
/// or as fast as possible for WER tests (P1.3). Timestamps are content time from the start of the file.
public final class FileCaptureSource: CaptureSource, @unchecked Sendable {
    public let id: CaptureSourceID
    public let frames: AsyncStream<PCMFrame>
    private let continuation: AsyncStream<PCMFrame>.Continuation
    private let url: URL
    private let realtime: Bool
    private let startOffset: TimeInterval
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(url: URL, realtime: Bool, startOffset: TimeInterval = 0) {
        self.url = url
        self.realtime = realtime
        self.startOffset = startOffset
        self.id = .file(url.deletingPathExtension().lastPathComponent)
        (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public func start() async throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        if startOffset > 0 { file.framePosition = AVAudioFramePosition(startOffset * format.sampleRate) }
        let converter = try PCMConverter(inputFormat: format)
        let (id, realtime, origin, continuation) = (id, realtime, startOffset, continuation)
        let t = Task.detached(priority: .userInitiated) {
            var chunker = FrameChunker(origin: origin, source: id)
            let clock = ContinuousClock()
            let anchor = clock.now
            let chunk = AVAudioFrameCount(format.sampleRate / 10)  // 100 ms reads
            while !Task.isCancelled {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
                // read throws at end of file on some formats; either way, drain the resampler tail
                let atEnd = (try? file.read(into: buffer, frameCount: chunk)) == nil || buffer.frameLength == 0
                let samples = atEnd ? ((try? converter.flush()) ?? []) : ((try? converter.convert(buffer)) ?? [])
                for frame in chunker.push(samples) {
                    if realtime {
                        try? await clock.sleep(until: anchor + .seconds(frame.timestamp - origin + 0.02))
                    }
                    continuation.yield(frame)
                }
                if atEnd { break }
            }
            continuation.finish()
        }
        lock.withLock { task = t }
    }

    public func stop() async {
        lock.withLock { task }?.cancel()
        continuation.finish()
    }
}
