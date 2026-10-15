import AVFoundation
import EarCore

/// Test helpers: what the phone's own recognizer hears in a buffer, and word error rate (a copy of the EarCoreTests
/// helper; test targets do not depend on each other).
enum Heard {
    static func text(_ samples: [Int16], sampleRate: Int) throws -> String {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.int16ChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        let pcm16k = try PCMConverter(inputFormat: format).convert(buffer)
        return try SherpaStreamingRecognizer(numThreads: 4).transcribeSegment(pcm16k)
    }

    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let words = { (s: String) in
            s.lowercased().replacingOccurrences(of: "'", with: "").split { !$0.isLetter && !$0.isNumber }.map(
                String.init)
        }
        let (r, h) = (words(reference), words(hypothesis))
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var cur = [i] + Array(repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }
}
