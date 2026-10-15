import Foundation

/// Capture → VAD → recognizer → store (P2.5). Frames are fed to the recognizer only while the VAD hears speech,
/// with 300 ms of pre-roll so word onsets are not clipped; each VAD speechEnd forces a final result.
/// Final results become `Segment`s (speaker "unknown" until P2.6); partial text is only published for the UI.
public final class AmbientPipeline: Sendable {
    public let store: SQLiteTranscriptStore
    private let vad: any VoiceActivityDetector
    private let recognizer: any StreamingRecognizer
    public let partials: AsyncStream<ASRResult>
    private let partialContinuation: AsyncStream<ASRResult>.Continuation
    public let finals: AsyncStream<Segment>
    private let finalContinuation: AsyncStream<Segment>.Continuation

    public init(store: SQLiteTranscriptStore, vad: any VoiceActivityDetector, recognizer: any StreamingRecognizer) {
        (self.store, self.vad, self.recognizer) = (store, vad, recognizer)
        (partials, partialContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
        (finals, finalContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Runs until the capture source finishes. `wallClock` maps pipeline time to dates (default: now).
    public func run(
        source: any CaptureSource, sessionID: String, locale: Locale = Locale(identifier: "en-US"),
        wallClock: @escaping @Sendable (TimeInterval) -> Date = { _ in Date() },
        onFrame: @escaping @Sendable (PCMFrame) -> Void = { _ in },
        divert: @escaping @Sendable (PCMFrame) -> Bool = { _ in false }
    ) async throws {
        try await recognizer.start(locale: locale)
        let writer = Task { [store, finalContinuation, partialContinuation, recognizer] in
            for await r in recognizer.results {
                guard r.isFinal else {
                    partialContinuation.yield(r)
                    continue
                }
                let seg = Segment(
                    sessionID: sessionID, t0: r.t0, t1: r.t1, wallClock: wallClock(r.t1), text: r.text,
                    confidence: r.confidence, source: source.id.description, engine: r.engine)
                if let id = try? await store.append(seg) {
                    var stored = seg
                    stored.id = id
                    finalContinuation.yield(stored)
                }
            }
        }
        try await source.start()
        // Every frame goes to the recognizer; the VAD only decides when an utterance is over. Silero's speechEnd
        // already trails real speech by its 300 ms hangover, which keeps soft endings ("twelve"). Gating the
        // recognizer by VAD clipped onsets and endings, and an extra post-roll split the next speaker's first syllable.
        // ponytail: decoding silence costs CPU (RTF ≈ 0.08 on an M1 Pro); gate again if device battery (A5) needs it.
        for await frame in source.frames {
            onFrame(frame)
            if divert(frame) { continue }  // push-to-talk question audio does not enter the transcript
            recognizer.feed(frame)
            if case .speechEnd = vad.process(frame) { await recognizer.finishUtterance() }
        }
        await recognizer.finishUtterance()
        await recognizer.stop()
        await writer.value
        finalContinuation.finish()
        partialContinuation.finish()
    }
}
