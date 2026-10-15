import XCTest

@testable import EarCore

/// A speaker that yields one chunk per sentence, tagged by sample rate, after `delay`; or nothing (`silent`).
final class FakeSpeaker: Speaker, @unchecked Sendable {
    let rate: Int
    let delay: TimeInterval
    let silent: Bool

    init(rate: Int, delay: TimeInterval = 0, silent: Bool = false) {
        self.rate = rate
        self.delay = delay
        self.silent = silent
    }

    func speak(sentences: AsyncStream<String>) -> AsyncStream<AudioChunk> {
        let (rate, delay, silent) = (rate, delay, silent)
        return AsyncStream { c in
            Task {
                for await _ in sentences {
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    if !silent { c.yield(AudioChunk(samples: [1, 2, 3], sampleRate: rate)) }
                }
                c.finish()
            }
        }
    }

    func stop() {}
}

final class FallbackSpeakerTests: XCTestCase {
    static let kokoro = 24_000, apple = 22_050

    private func rates(_ s: Speaker, _ sentences: [String]) async -> [Int] {
        let (stream, c) = AsyncStream.makeStream(of: String.self)
        for s in sentences { c.yield(s) }
        c.finish()
        var out: [Int] = []
        for await chunk in s.speak(sentences: stream) { out.append(chunk.sampleRate) }
        return out
    }

    func testHealthyPrimarySpeaksEverySentence() async {
        let s = FallbackSpeaker(primary: FakeSpeaker(rate: Self.kokoro), fallback: FakeSpeaker(rate: Self.apple))
        let r = await rates(s, ["One.", "Two."])
        XCTAssertEqual(r, [Self.kokoro, Self.kokoro])
    }

    func testOneSlowSentenceUsesTheFallbackButKeepsThePrimary() async {
        let s = FallbackSpeaker(
            primary: FakeSpeaker(rate: Self.kokoro, delay: 0.3), fallback: FakeSpeaker(rate: Self.apple),
            sentenceTimeout: 0.1)
        let r = await rates(s, ["One."])
        XCTAssertEqual(r, [Self.apple])
        XCTAssertTrue(s.primaryHealthy, "one slow sentence must not switch Kokoro off")
    }

    func testRepeatedTimeoutsSwitchThePrimaryOff() async {
        let s = FallbackSpeaker(
            primary: FakeSpeaker(rate: Self.kokoro, delay: 0.3), fallback: FakeSpeaker(rate: Self.apple),
            sentenceTimeout: 0.1, maxTimeouts: 2)
        let r = await rates(s, ["One.", "Two.", "Three."])
        XCTAssertEqual(r, [Self.apple, Self.apple, Self.apple])
        XCTAssertFalse(s.primaryHealthy)
    }

    func testPrimaryWithNoAudioIsSwitchedOffAtOnce() async {
        let s = FallbackSpeaker(
            primary: FakeSpeaker(rate: Self.kokoro, silent: true), fallback: FakeSpeaker(rate: Self.apple))
        let r = await rates(s, ["One."])
        XCTAssertEqual(r, [Self.apple])
        XCTAssertFalse(s.primaryHealthy, "no audio means Kokoro is broken, not slow")
    }

    func testMarkingThePrimaryUnhealthyUsesTheFallback() async {
        let s = FallbackSpeaker(primary: FakeSpeaker(rate: Self.kokoro), fallback: FakeSpeaker(rate: Self.apple))
        s.markPrimaryUnhealthy()  // what the app does on a memory warning
        let r = await rates(s, ["One."])
        XCTAssertEqual(r, [Self.apple])
    }

    func testStopDropsQueuedSentences() async {
        let s = FallbackSpeaker(
            primary: FakeSpeaker(rate: Self.kokoro, delay: 0.05), fallback: FakeSpeaker(rate: Self.apple))
        let (stream, c) = AsyncStream.makeStream(of: String.self)
        for s in ["One.", "Two.", "Three.", "Four."] { c.yield(s) }
        c.finish()
        var spoken = 0
        for await _ in s.speak(sentences: stream) {
            spoken += 1
            if spoken == 1 { s.stop() }  // the user taps Stop while the first sentence plays
        }
        XCTAssertEqual(spoken, 1, "no sentence after stop()")
        XCTAssertTrue(s.primaryHealthy, "stopping is not a failure")
    }

    func testCountsWhichVoiceSpokeEachSentence() async {
        let s = FallbackSpeaker(
            primary: FakeSpeaker(rate: Self.kokoro, delay: 0.3), fallback: FakeSpeaker(rate: Self.apple),
            sentenceTimeout: 0.1, maxTimeouts: 5)
        _ = await rates(s, ["One.", "Two."])
        XCTAssertEqual(s.spokenByPrimary, 0)
        XCTAssertEqual(s.spokenByFallback, 2)
    }
}
