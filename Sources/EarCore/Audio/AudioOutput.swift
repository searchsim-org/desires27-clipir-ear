@preconcurrency import AVFoundation
import Foundation

public struct AudioChunk: Sendable {
    public var samples: [Int16]
    public let sampleRate: Int
    public init(samples: [Int16], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
    public var duration: TimeInterval { Double(samples.count) / Double(sampleRate) }
}

/// Plays `AudioChunk`s in order through one player node; `stop()` flushes everything queued (P1.4).
/// `manualRendering: true` renders offline for tests (no device needed).
public final class AudioOutput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var pending = 0  // guarded by lock
    public let sampleRate: Int

    private var pump: DispatchSourceTimer?

    /// `manualRendering`: offline render pulled by tests via `render(frames:)`.
    /// `silent`: offline render pumped at real-time pace (harness and tests: real timing, no sound).
    public init(sampleRate: Int = 24_000, manualRendering: Bool = false, silent: Bool = false) throws {
        self.sampleRate = sampleRate
        format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        if manualRendering || silent {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        }
        engine.prepare()
        try engine.start()
        player.play()
        if silent {
            let frames = sampleRate / 50  // 20 ms per tick
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "earcore.audio.silent-pump"))
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in _ = try? self?.render(frames: frames) }
            timer.resume()
            pump = timer
        }
    }

    deinit { pump?.cancel() }

    /// Queue a chunk; `onPlayed` fires when it has been rendered.
    public func enqueue(_ chunk: AudioChunk, onPlayed: (@Sendable () -> Void)? = nil) {
        let samples =
            chunk.sampleRate == sampleRate
            ? chunk.samples : Self.resample(chunk.samples, from: chunk.sampleRate, to: sampleRate)
        guard !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = buffer.frameCapacity
        let out = buffer.floatChannelData![0]
        for i in samples.indices { out[i] = Float(samples[i]) / 32768 }
        lock.withLock { pending += 1 }
        player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
            self?.lock.withLock { self?.pending = max(0, (self?.pending ?? 1) - 1) }
            onPlayed?()
        }
    }

    public var isPlaying: Bool { lock.withLock { pending > 0 } }

    /// Stops playback immediately and drops anything queued.
    public func stop() {
        player.stop()
        lock.withLock { pending = 0 }
        player.play()
    }

    /// Offline render (manualRendering only): pulls `frames` samples through the graph.
    public func render(frames: Int) throws -> [Float] {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(frames))!
        var out: [Float] = []
        while out.count < frames {
            let status = try engine.renderOffline(AVAudioFrameCount(min(4096, frames - out.count)), to: buffer)
            guard status == .success else { break }
            out += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        return out
    }

    /// Linear resampling; good enough for earcons and TTS prompts.
    public static func resample(_ x: [Int16], from: Int, to: Int) -> [Int16] {
        guard from != to, !x.isEmpty else { return x }
        let n = Int(Double(x.count) * Double(to) / Double(from))
        return (0..<n).map { i in
            let p = Double(i) * Double(from) / Double(to)
            let j = Int(p)
            let f = p - Double(j)
            let a = Double(x[min(j, x.count - 1)])
            let b = Double(x[min(j + 1, x.count - 1)])
            return Int16(a + (b - a) * f)
        }
    }
}
