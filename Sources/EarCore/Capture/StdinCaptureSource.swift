import Foundation

/// Raw PCM16 mono 16 kHz from a file handle (stdin), for `EarCLI asr-stream` under earbridge (ADR-015).
/// Timestamps are sample-accurate from the first byte.
public final class StdinCaptureSource: CaptureSource, @unchecked Sendable {
    public let id = CaptureSourceID.remote
    public let frames: AsyncStream<PCMFrame>
    private let continuation: AsyncStream<PCMFrame>.Continuation
    private let handle: FileHandle

    public init(handle: FileHandle = .standardInput) {
        self.handle = handle
        (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public func start() async throws {
        let (handle, continuation) = (handle, continuation)
        Thread.detachNewThread {
            var chunker = FrameChunker(source: .remote)
            var carry = Data()
            while true {
                let data = handle.availableData  // blocks; empty = EOF
                if data.isEmpty { break }
                carry.append(data)
                let usable = carry.count & ~1
                let samples = carry.prefix(usable).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
                carry.removeFirst(usable)
                for f in chunker.push(samples) { continuation.yield(f) }
            }
            continuation.finish()
        }
    }

    public func stop() async { continuation.finish() }
}
