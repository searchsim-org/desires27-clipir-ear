import AVFoundation
import Foundation

/// Explicit Record (P8.3, PRIVACY §10.1): the only code that writes captured audio to disk, and only while the user
/// has Record on. 16 kHz mono 16-bit WAV.
public final class Recorder: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var span: (TimeInterval, TimeInterval)?

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
    }

    public func write(_ frame: PCMFrame) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, !frame.samples.isEmpty,
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.samples.count))
        else { return }
        buf.frameLength = buf.frameCapacity
        frame.samples.withUnsafeBufferPointer {
            buf.int16ChannelData![0].update(from: $0.baseAddress!, count: $0.count)
        }
        try? file.write(from: buf)
        let end = frame.timestamp + Double(frame.samples.count) / Double(frame.sampleRate)
        span = (span?.0 ?? frame.timestamp, end)
    }

    /// Closes the file; returns the pipeline-time span that was recorded (nil if nothing was).
    public func finish() -> (TimeInterval, TimeInterval)? {
        lock.lock()
        defer { lock.unlock() }
        file = nil  // AVAudioFile finalises the WAV header on release
        return span
    }
}

/// The recorder the capture loop writes to; swapped while ambient mode runs.
final class FrameHook: @unchecked Sendable {
    private let lock = NSLock()
    private var _recorder: Recorder?
    var recorder: Recorder? {
        get { lock.withLock { _recorder } }
        set { lock.withLock { _recorder = newValue } }
    }
}
