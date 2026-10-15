import Foundation
import Synchronization

/// Speaks through `primary` (Kokoro) and uses `fallback` (the Apple voice) when the primary cannot speak a sentence
/// in time (ADR-020). One sentence at a time, so a switch never splits a sentence across two voices.
public final class FallbackSpeaker: Speaker, @unchecked Sendable {
    private let primary: Speaker?
    private let fallback: Speaker
    private let sentenceTimeout: TimeInterval
    private let maxTimeouts: Int
    private struct State {
        var healthy: Bool
        var timeouts = 0
        var stopped = false
        var byPrimary = 0
        var byFallback = 0
    }
    private let state: Mutex<State>

    /// A sentence the primary does not finish within `sentenceTimeout` is spoken by the fallback; after
    /// `maxTimeouts` such sentences in a row the primary is switched off for this speaker's lifetime.
    public init(primary: Speaker?, fallback: Speaker, sentenceTimeout: TimeInterval = 6, maxTimeouts: Int = 3) {
        (self.primary, self.fallback) = (primary, fallback)
        (self.sentenceTimeout, self.maxTimeouts) = (sentenceTimeout, maxTimeouts)
        state = Mutex(State(healthy: primary != nil))
    }

    public var primaryHealthy: Bool { state.withLock { $0.healthy } }
    /// Sentences each voice has spoken so far (KokoroLoopBench reports them).
    public var spokenByPrimary: Int { state.withLock { $0.byPrimary } }
    public var spokenByFallback: Int { state.withLock { $0.byFallback } }

    /// Switches to the fallback for the rest of this speaker's life (the app calls this on a memory warning).
    public func markPrimaryUnhealthy() { state.withLock { $0.healthy = false } }

    public func speak(sentences: AsyncStream<String>) -> AsyncStream<AudioChunk> {
        state.withLock { $0.stopped = false }
        let (out, c) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        let task = Task { [self] in
            for await sentence in sentences {
                if isStopped { break }
                var chunks: [AudioChunk]? = nil
                if let primary, primaryHealthy { chunks = await render(primary, sentence) }
                let byPrimary = chunks != nil
                if chunks == nil, !isStopped { chunks = await Self.collectAudio(fallback, sentence) }
                if isStopped { break }
                state.withLock {
                    if byPrimary { $0.byPrimary += 1 } else { $0.byFallback += 1 }
                }
                for chunk in chunks ?? [] { c.yield(chunk) }
            }
            c.finish()
        }
        c.onTermination = { _ in task.cancel() }
        return out
    }

    /// Stops the current sentence and drops every queued one, for both voices.
    public func stop() {
        state.withLock { $0.stopped = true }
        primary?.stop()
        fallback.stop()
    }

    private var isStopped: Bool { state.withLock { $0.stopped } }

    private enum Outcome {
        case audio([AudioChunk])
        case noAudio  // the primary finished without audio: an error, not slowness
        case timedOut
    }

    /// The primary's audio for one sentence, or nil (timed out or no audio); updates the health counters.
    private func render(_ speaker: Speaker, _ sentence: String) async -> [AudioChunk]? {
        let timeout = sentenceTimeout
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                let chunks = await Self.collectAudio(speaker, sentence)
                return chunks.isEmpty ? .noAudio : .audio(chunks)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        let maxTimeouts = maxTimeouts
        return state.withLock { s in
            if s.stopped { return nil }  // a render cut short by stop() is not a failure
            switch outcome {
            case .audio(let chunks):
                s.timeouts = 0
                return chunks
            case .noAudio:
                s.healthy = false
                return nil
            case .timedOut:
                s.timeouts += 1
                if s.timeouts >= maxTimeouts { s.healthy = false }
                return nil
            }
        }
    }

    /// Every chunk `speaker` produces for one sentence.
    static func collectAudio(_ speaker: Speaker, _ sentence: String) async -> [AudioChunk] {
        var chunks: [AudioChunk] = []
        for await chunk in speaker.speak(sentences: singleSentence(sentence)) { chunks.append(chunk) }
        return chunks
    }

    /// A finished stream holding one sentence.
    public static func singleSentence(_ s: String) -> AsyncStream<String> {
        let (stream, c) = AsyncStream.makeStream(of: String.self)
        c.yield(s)
        c.finish()
        return stream
    }
}
