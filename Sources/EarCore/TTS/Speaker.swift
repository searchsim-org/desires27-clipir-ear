@preconcurrency import AVFoundation
import Foundation
import Synchronization

public protocol Speaker: AnyObject, Sendable {
    func speak(sentences: AsyncStream<String>) -> AsyncStream<AudioChunk>  // streaming synthesis
    func stop()
}

/// Apple TTS rendered to PCM (P4.1): `write(_:toBufferCallback:)` instead of letting the synthesizer play, so routing
/// and ducking stay with `AudioOutput`. The phone's only speaker (ADR-007). Sentence n+1 is synthesised as soon as
/// sentence n's audio has been handed over, so playback of n overlaps synthesis of n+1.
public final class SystemSpeaker: Speaker, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private let rate: Float
    private let stopped = Mutex(false)

    public init(
        language: String = "en-US", voiceIdentifier: String? = nil, rate: Float = AVSpeechUtteranceDefaultSpeechRate
    ) {
        voice =
            voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? Self.bestVoice(language: language)
        self.rate = rate
    }

    /// Installed voices for `language`'s language (e.g. every "en-*"), best first: Premium, then Enhanced, then the
    /// compact default; the exact region first within a quality; novelty voices (Zarvox, Bubbles, …) left out.
    /// `AVSpeechSynthesisVoice(language:)` returns the compact voice even when a Premium one is installed.
    public static func voices(language: String = "en-US") -> [AVSpeechSynthesisVoice] {
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { rank($0, language) > rank($1, language) }
    }

    /// Quality, then Apple's current voice family over the older robotic ones (Eloquence, MacinTalk), then region.
    static func rank(_ v: AVSpeechSynthesisVoice, _ language: String) -> (Int, Int, Int, String) {
        let legacy = v.identifier.contains("eloquence") || v.identifier.contains("speech.synthesis.voice")
        return (v.quality.rawValue, legacy ? 0 : 1, v.language == language ? 1 : 0, v.name)
    }

    public static func bestVoice(language: String = "en-US") -> AVSpeechSynthesisVoice? {
        voices(language: language).first ?? AVSpeechSynthesisVoice(language: language)
    }

    /// The voice actually used, for Settings and the latency log.
    public var voiceName: String { voice.map { "\($0.name) (\(Self.qualityName($0.quality)))" } ?? "system default" }

    public static func qualityName(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Compact"
        }
    }

    public func speak(sentences: AsyncStream<String>) -> AsyncStream<AudioChunk> {
        stopped.withLock { $0 = false }
        let (out, c) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        let task = Task { [self] in
            for await sentence in sentences {
                if stopped.withLock({ $0 }) { break }
                for await chunk in synthesize(sentence) { c.yield(chunk) }
            }
            c.finish()
        }
        c.onTermination = { _ in task.cancel() }
        return out
    }

    /// One utterance → its PCM chunks (Int16, the synthesizer's native rate).
    public func synthesize(_ text: String) -> AsyncStream<AudioChunk> {
        let (out, c) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = rate
        synthesizer.write(u) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0, let self, !self.stopped.withLock({ $0 })
            else {
                c.finish()  // an empty buffer marks the end of the utterance
                return
            }
            c.yield(AudioChunk(samples: Self.int16(pcm), sampleRate: Int(pcm.format.sampleRate)))
        }
        return out
    }

    static func int16(_ b: AVAudioPCMBuffer) -> [Int16] {
        let n = Int(b.frameLength)
        if let p = b.int16ChannelData { return Array(UnsafeBufferPointer(start: p[0], count: n)) }
        guard let f = b.floatChannelData else { return [] }
        return (0..<n).map { Int16(max(-1, min(1, f[0][$0])) * 32767) }
    }

    public func stop() {
        stopped.withLock { $0 = true }
        synthesizer.stopSpeaking(at: .immediate)
    }
}
