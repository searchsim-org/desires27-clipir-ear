@preconcurrency import AVFoundation
import Foundation

/// Generates test audio on the fly so unit tests do not depend on fixtures.
enum TestAudio {
    static func sineBuffer(
        seconds: Double, rate: Double = 48_000, channels: AVAudioChannelCount = 2, hz: Double = 440,
        amplitude: Float = 0.5
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let n = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        buffer.frameLength = n
        for c in 0..<Int(channels) {
            let p = buffer.floatChannelData![c]
            for i in 0..<Int(n) { p[i] = amplitude * Float(sin(2 * .pi * hz * Double(i) / rate)) }
        }
        return buffer
    }

    static func writeWav(seconds: Double, rate: Double = 48_000, channels: AVAudioChannelCount = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("earcore-\(UUID().uuidString).wav")
        let buffer = sineBuffer(seconds: seconds, rate: rate, channels: channels)
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try file.write(from: buffer)
        return url
    }

    /// A spoken phrase (macOS `say`, 16 kHz mono) for tests that need real speech without a fixture. Fixed rate and
    /// 0.5 s lead-in, like a real push-to-talk press: speech at sample 0 loses its first word on the Mac's recognizer.
    static func spoken(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("earcore-\(UUID().uuidString).wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "-r", "170", "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", "[[slnc 500]] " + text,
        ]
        try say.run()
        say.waitUntilExit()
        return url
    }

    static func rms(_ x: [Int16]) -> Double {
        (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))).squareRoot()
    }
}
