import EarCore
import XCTest

@testable import EarTTSKokoro

/// Kokoro through the Speaker interface, with the real model (ADR-020). Run with `make test-kokoro` (xcodebuild).
final class KokoroSpeakerTests: XCTestCase {
    private func speaker() throws -> KokoroSpeaker {
        do { return try KokoroSpeaker(voice: KokoroSpeaker.defaultVoice) } catch {
            throw XCTSkip("Kokoro model missing: make models ONLY=\"kokoro-82m kokoro-voice-af_heart\" (\(error))")
        }
    }

    private func speak(_ s: Speaker, _ text: String) async -> [AudioChunk] {
        let (stream, c) = AsyncStream.makeStream(of: String.self)
        c.yield(text)
        c.finish()
        var chunks: [AudioChunk] = []
        for await chunk in s.speak(sentences: stream) { chunks.append(chunk) }
        return chunks
    }

    func testSpeaksAWholeSentenceAt24kHz() async throws {
        let chunks = await speak(try speaker(), "The oldest stone bridge was built in eleven forty.")
        XCTAssertEqual(chunks.map(\.sampleRate), [24_000])
        let seconds = Double(chunks.map(\.samples.count).reduce(0, +)) / 24_000
        XCTAssertGreaterThan(seconds, 1.5, "a ten-word sentence lasts about 3 s")
    }

    /// Objective intelligibility: the phone's own recognizer (Zipformer) must understand Kokoro.
    func testThePhonesRecognizerUnderstandsKokoro() async throws {
        let text = "The oldest stone bridge was built in eleven forty and parts of it still stand"
        let audio = try await speaker().render(text)
        let heard = try Heard.text(audio, sampleRate: KokoroSpeaker.sampleRate)
        let wer = Heard.wordErrorRate(reference: text, hypothesis: heard)
        XCTAssertLessThan(wer, 0.15, "heard: \(heard)")
    }

    func testInstalledVoicesListsTheDefaultVoice() throws {
        _ = try speaker()  // skips without the model
        let voices = KokoroSpeaker.installedVoices()
        XCTAssertTrue(voices.contains(KokoroSpeaker.defaultVoice), "\(voices)")
        XCTAssertFalse(voices.contains { $0.hasSuffix(".npy") }, "\(voices)")
    }
}
