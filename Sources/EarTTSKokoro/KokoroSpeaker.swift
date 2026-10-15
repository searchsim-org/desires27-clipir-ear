import EarCore
import Foundation
import KokoroSwift
import MLX
import MLXUtilsLibrary
import Synchronization
import ZIPFoundation

/// Kokoro-82M through KokoroSwift + MisakiSwift (ADR-020): one sentence at a time, 24 kHz mono. KokoroTTS is not
/// thread-safe, so every render runs on one serial queue. Model files live in `Models.directory/kokoro`.
public final class KokoroSpeaker: Speaker, @unchecked Sendable {
    public static let sampleRate = KokoroTTS.Constants.samplingRate  // 24 000
    public static let defaultVoice = "af_heart"  // ADR-020
    private let tts: KokoroTTS
    private let style: MLXArray
    private let british: Bool
    private let queue = DispatchQueue(label: "de.zerhoudi.clipir-ear.kokoro")
    private let stopped = Mutex(false)
    public let voice: String

    public init(voice: String) throws {
        let dir = Models.directory.appendingPathComponent("kokoro")
        let model = dir.appendingPathComponent("kokoro-v1_0.safetensors")
        guard FileManager.default.fileExists(atPath: model.path),
            let voices = NpyzReader.read(fileFromPath: dir.appendingPathComponent("voices.npz")),
            let style = voices[voice + ".npy"]
        else { throw EarError.notFound("Kokoro model or voice \(voice) (make models ONLY=\"kokoro-…\")") }
        tts = KokoroTTS(modelPath: model, g2p: .misaki)
        self.style = style
        british = voice.hasPrefix("b")
        self.voice = voice
    }

    /// Hands MLX's cached GPU buffers back to iOS (memory warning, ADR-020).
    public static func releaseCaches() { MLX.GPU.clearCache() }

    /// The voices in voices.npz, e.g. ["af_heart", "am_michael", …]. Reads the zip's directory only, never the
    /// voice arrays; cheap enough to call when Settings appears (not in a SwiftUI `body`).
    public static func installedVoices() -> [String] {
        let url = Models.directory.appendingPathComponent("kokoro/voices.npz")
        guard let archive = try? Archive(url: url, accessMode: .read) else { return [] }
        return archive.map { $0.path.replacingOccurrences(of: ".npy", with: "") }.sorted()
    }

    /// One short render in the background, so shader compilation and lazy weight loading do not land on the first
    /// answer (FallbackSpeaker would time it out).
    public func warmUp() {
        queue.async { [self] in _ = try? tts.generateAudio(voice: style, language: .enUS, text: "Ready.") }
    }

    /// One sentence → 16-bit samples at `sampleRate`. Empty when stopped before it ran.
    public func render(_ text: String) async throws -> [Int16] {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                if stopped.withLock({ $0 }) { return cont.resume(returning: []) }
                do {
                    let (audio, _) = try tts.generateAudio(voice: style, language: british ? .enGB : .enUS, text: text)
                    cont.resume(returning: audio.map { Int16(max(-1, min(1, $0)) * 32_767) })
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    public func speak(sentences: AsyncStream<String>) -> AsyncStream<AudioChunk> {
        stopped.withLock { $0 = false }
        let (out, c) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        let task = Task { [self] in
            for await sentence in sentences {
                if stopped.withLock({ $0 }) { break }
                // a failed render yields nothing; FallbackSpeaker then speaks the sentence with the Apple voice
                guard let pcm = try? await render(sentence), !pcm.isEmpty else { continue }
                c.yield(AudioChunk(samples: pcm, sampleRate: Self.sampleRate))
            }
            c.finish()
        }
        c.onTermination = { _ in task.cancel() }
        return out
    }

    public func stop() { stopped.withLock { $0 = true } }
}
