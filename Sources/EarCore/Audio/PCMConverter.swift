@preconcurrency import AVFoundation

/// Converts any PCM buffer to 16 kHz mono Int16 (§3.4). Stateful: keeps the resampler tail between calls.
/// Re-create it when the input format changes (route switch, P1.2).
public final class PCMConverter {
    public static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    public let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public init(inputFormat: AVAudioFormat) throws {
        guard let c = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else {
            throw EarError.audio("no converter from \(inputFormat)")
        }
        c.downmix = true  // stereo → mono averages channels instead of dropping one
        self.inputFormat = inputFormat
        self.converter = c
    }

    public func convert(_ buffer: AVAudioPCMBuffer) throws -> [Int16] {
        try run(buffer, endOfStream: false)
    }

    /// Drains the resampler at end of stream.
    public func flush() throws -> [Int16] {
        try run(nil, endOfStream: true)
    }

    private func run(_ buffer: AVAudioPCMBuffer?, endOfStream: Bool) throws -> [Int16] {
        let ratio = Self.outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer?.frameLength ?? 0) * ratio) + 1024
        var result: [Int16] = []
        var fed = false
        while true {
            let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity)!
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if let buffer, !fed {
                    fed = true
                    inputStatus.pointee = .haveData
                    return buffer
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw EarError.audio(error.localizedDescription) }
            if out.frameLength > 0 {
                result += UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength))
            }
            if status != .haveData || out.frameLength == 0 { break }
        }
        return result
    }
}
