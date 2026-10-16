import Foundation
import Synchronization

public struct PipelineConfig: Sendable {
    public var locale = Locale(identifier: "en-US")
    public var tier: Tier = .phone
    public var maxTokens = 160
    public var deviceModel = "unknown"
    public var tierPolicy = "phone"
    public var policy = TierPolicy(mode: .auto)  // P5.6: decides per question when a Mac is paired
    public init() {}
}

public struct PipelineDeps: Sendable {
    public var store: SQLiteTranscriptStore
    public var makeSource: @Sendable () throws -> any CaptureSource
    public var makeVAD: @Sendable () throws -> any VoiceActivityDetector
    public var makeRecognizer: @Sendable () throws -> any StreamingRecognizer
    public var answerer: any Answerer
    public var embedder: (any Embedder)?
    public var speaker: (any Speaker)?  // Phase 4: whisper-back
    public var output: AudioOutput?
    public var bridge: BridgeClient?  // Phase 5: paired Mac (nil = phone only)
    public var executor: (any ActionExecutor)?  // Phase 6: nil = EarActionExecutor over this store + EventKit

    public init(
        store: SQLiteTranscriptStore, makeSource: @escaping @Sendable () throws -> any CaptureSource,
        makeVAD: @escaping @Sendable () throws -> any VoiceActivityDetector,
        makeRecognizer: @escaping @Sendable () throws -> any StreamingRecognizer, answerer: any Answerer,
        embedder: (any Embedder)? = nil, speaker: (any Speaker)? = nil, output: AudioOutput? = nil,
        bridge: BridgeClient? = nil, executor: (any ActionExecutor)? = nil
    ) {
        (self.store, self.makeSource, self.makeVAD, self.makeRecognizer) = (store, makeSource, makeVAD, makeRecognizer)
        (self.answerer, self.embedder, self.speaker, self.output) = (answerer, embedder, speaker, output)
        self.bridge = bridge
        self.executor = executor
    }
}

public enum PipelineState: Sendable, Equatable {
    case idle
    case listening(route: String)
    case interrupted(reason: String)
    case ended(reason: String)
    case capturingQuestion
    case answering(tier: String)
    case speaking
    case awaitingApproval(EarAction)
}

public struct QueryHandle: Sendable {
    public let queryID: Int64  // voice_queries.id
    public let events: AsyncStream<AnswerEvent>  // mirrors what is being spoken
    public let trace: LatencyTrace
    public let question: String
    public let intent: Intent
}

/// One-shot flag shared between tasks.
final class Flag: Sendable {
    private let v = Mutex(false)
    var isSet: Bool { v.withLock { $0 } }
    /// Sets the flag; true only for the caller that set it first.
    func setFirst() -> Bool {
        v.withLock { x in
            defer { x = true }
            return !x
        }
    }
}

/// Frames are diverted here while push-to-talk is held, so the question never enters the transcript.
final class QueryTap: Sendable {
    private let recognizer = Mutex<(any StreamingRecognizer)?>(nil)
    private let forward = Mutex<AsyncStream<[Int16]>.Continuation?>(nil)  // Mac tier: question audio to the Mac too
    func set(_ r: (any StreamingRecognizer)?) { recognizer.withLock { $0 = r } }
    func setForward(_ c: AsyncStream<[Int16]>.Continuation?) {
        forward.withLock { old in
            old?.finish()
            old = c
        }
    }
    func take() -> (any StreamingRecognizer)? {
        recognizer.withLock { r in
            defer { r = nil }
            return r
        }
    }
    func divert(_ frame: PCMFrame) -> Bool {
        guard let r = recognizer.withLock({ $0 }) else { return false }
        r.feed(frame)
        forward.withLock { $0?.yield(frame.samples) }
        return true
    }
}

/// The one object the app talks to (§5): ambient transcription plus the push-to-talk query path.
public actor EarPipeline {
    public let config: PipelineConfig
    public let deps: PipelineDeps
    public nonisolated let state: AsyncStream<PipelineState>
    private let stateContinuation: AsyncStream<PipelineState>.Continuation
    public nonisolated let partials: AsyncStream<String>
    private let partialContinuation: AsyncStream<String>.Continuation
    public nonisolated let finals: AsyncStream<Segment>
    private let finalContinuation: AsyncStream<Segment>.Continuation
    public nonisolated let levels: AsyncStream<Float>
    private let levelContinuation: AsyncStream<Float>.Continuation

    private let tap = QueryTap()
    private var source: (any CaptureSource)?
    private var ambientTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var trace: LatencyTrace?
    private var router = QueryRouter()
    private var sessionID: String?
    public private(set) var lastAnswer: String?
    private var remoteQueryID: String?  // set by beginQuery when the Mac tier answers this question
    // ambient PCM mirrored to the Mac (its store serves Mac-tier retrieval)
    private var mirror: RemoteRecognizer?
    private var replyContinuation: AsyncStream<String?>.Continuation?  // approval reply (spoken or on-screen)
    private var earlyReply: String?  // an on-screen answer given while the proposal was still being spoken
    private let intents: IntentDetector
    private var cues: CueEngine?  // P8.6: nil = off (the default)
    private var recorder: Recorder?  // P8.3: explicit Record only
    private let frameHook = FrameHook()

    public init(config: PipelineConfig, deps: PipelineDeps) {
        (self.config, self.deps) = (config, deps)
        intents = IntentDetector(locale: config.locale)
        (state, stateContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        (partials, partialContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (finals, finalContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (levels, levelContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        // no initial .idle: a late subscriber would read it after listening started and reset its UI
    }

    public var isAmbientRunning: Bool { ambientTask != nil }

    // MARK: cues (P8.6) and Record (P8.3)

    public func setCues(enabled: Bool) { cues = enabled ? (cues ?? CueEngine()) : nil }

    private func maybeCue(_ s: Segment) async {
        guard cues != nil, router.state == .idle else { return }  // never over a question or an answer
        let notes = ((try? await deps.store.notes()) ?? []).map(\.text)
        let pinned = ((try? await deps.store.pinned()) ?? []).filter { $0.id != s.id }.map(\.text)
        guard let line = cues?.cue(for: s.text, keywords: CueEngine.keywords(from: notes + pinned), at: s.t1)
        else { return }
        var vq = VoiceQuery(
            sessionID: sessionID ?? "", question: "(cue)", intent: "cue", answer: line, model: "none")
        let t = LatencyTrace()
        vq.latencyJSON = t.json(extras: ["cue": true])
        _ = try? await deps.store.save(vq)  // logged like every other spoken line (P8.6)
        await say(line, trace: t)
    }

    /// Starts writing the ambient audio to `url` (WAV, 16 kHz mono); returns the pipeline time it started at.
    public func startRecording(to url: URL) throws {
        let r = try Recorder(url: url)
        recorder = r
        frameHook.recorder = r
    }

    /// Stops recording and marks the segments it covers `audio_retained = 1`. Returns the file, if any.
    @discardableResult
    public func stopRecording() async -> URL? {
        guard let r = recorder else { return nil }
        (recorder, frameHook.recorder) = (nil, nil)
        let span = r.finish()
        if let sessionID, let span {
            try? await deps.store.markAudioRetained(session: sessionID, from: span.0, to: span.1)
        }
        return r.url
    }

    /// Capture statistics for the Debug screen (P1.6); file sources report no drops.
    public func captureStats() -> MicCaptureSource.Stats? { (source as? MicCaptureSource)?.stats() }

    // MARK: ambient

    public func startAmbient() async throws {
        guard ambientTask == nil else { return }
        let source = try deps.makeSource()
        let ambient = AmbientPipeline(store: deps.store, vad: try deps.makeVAD(), recognizer: try deps.makeRecognizer())
        let session = try await deps.store.startSession(
            {
                var s = SessionInfo(captureSource: source.id.description, deviceModel: config.deviceModel)
                s.tierPolicy = config.tierPolicy
                return s
            }())
        (self.source, sessionID) = (source, session)
        let (tap, partialC, finalC, levelC) = (tap, partialContinuation, finalContinuation, levelContinuation)
        let forwardPartials = Task { for await p in ambient.partials { partialC.yield(p.text) } }
        let forwardFinals = Task { [weak self] in
            for await s in ambient.finals {
                finalC.yield(s)
                await self?.maybeCue(s)
            }
        }
        stateContinuation.yield(.listening(route: source.id.description))
        if let llm = deps.answerer as? LlamaAnswerer {  // P3.5: keep the model warm while ambient mode is on
            Task.detached(priority: .utility) { _ = try? llm.warm() }
        }
        if let embedder = deps.embedder {  // P3.3: embed new segments in the background, 1 per second
            let indexer = EmbeddingIndexer(store: deps.store, embedder: embedder, model: "nomic-embed-text-v1.5")
            indexTask = Task.detached(priority: .utility) { await indexer.run(perSecond: 1) }
        }
        if let bridge = deps.bridge, config.policy.mode != .phone, await bridge.isConnected {
            let m = RemoteRecognizer(bridge: bridge, sessionID: session)
            try? await m.start(locale: config.locale)
            mirror = m
        }
        let mirror = mirror
        let hook = frameHook
        ambientTask = Task { [weak self] in
            do {
                try await ambient.run(
                    source: source, sessionID: session, locale: self?.config.locale ?? .current,
                    onFrame: {
                        levelC.yield(min(1, $0.rms * 8))
                        hook.recorder?.write($0)
                    },
                    divert: { frame in
                        if tap.divert(frame) { return true }
                        mirror?.feed(frame)
                        return false
                    })
            } catch {
                await self?.ended("capture failed: \(error)")
            }
            await forwardPartials.value
            await forwardFinals.value
            await self?.ambientFinished()
        }
    }

    public func stopAmbient() async {
        await source?.stop()
        await ambientTask?.value
    }

    /// For finite sources (fixtures, tests): returns when the source has played out.
    public func waitUntilAmbientEnds() async { await ambientTask?.value }

    private func ambientFinished() async {
        await mirror?.stop()
        mirror = nil
        ambientTask = nil
        indexTask?.cancel()
        indexTask = nil
        source = nil
        if let sessionID { try? await deps.store.endSession(sessionID) }
        stateContinuation.yield(.idle)
    }

    private func ended(_ reason: String) { stateContinuation.yield(.ended(reason: reason)) }

    // MARK: query path

    /// PTT down: open query capture (frames from the running capture source go to a fresh recognizer).
    public func beginQuery() async {
        let t = LatencyTrace()
        t.mark(.pttDown)
        trace = t
        deps.answerer.cancel()  // barge-in
        router.handle(.pttDown)
        guard let r = try? deps.makeRecognizer() else { return }
        try? await r.start(locale: config.locale)
        Self.prime(r)
        tap.set(r)
        remoteQueryID = nil
        if let bridge = deps.bridge, config.policy.mode != .phone,
            config.policy.choose(connected: await bridge.isConnected, rtt: await bridge.rtt) == .mac
        {
            let qid = UUID().uuidString
            remoteQueryID = qid
            await bridge.send("query.begin", ["query_id": qid, "session_id": sessionID ?? ""])
            let (pcm, c) = AsyncStream.makeStream(of: [Int16].self, bufferingPolicy: .unbounded)
            tap.setForward(c)
            Task { for await samples in pcm { await bridge.sendPCM(samples) } }  // in order, as the user speaks
        }
        stateContinuation.yield(.capturingQuestion)
    }

    /// PTT up: finalise the question, route, assemble, answer (P3.1/P3.5; TTS added in Phase 4).
    public func endQuery() async throws -> QueryHandle {
        let t = trace ?? LatencyTrace()
        t.mark(.speechEnd)
        playEarcon(.listening, trace: t)
        router.handle(.pttUp)
        guard let r = tap.take() else { throw EarError.cancelled }
        tap.setForward(nil)
        if let qid = remoteQueryID, let bridge = deps.bridge {
            remoteQueryID = nil
            return try await remoteAnswer(queryID: qid, bridge: bridge, local: r, trace: t)
        }
        await r.stop()  // finalises pending audio and closes the stream
        var question = ""
        for await res in r.results where res.isFinal { question += (question.isEmpty ? "" : " ") + res.text }
        t.mark(.asrFinal)
        router.handle(.asrFinal)
        guard !question.isEmpty else {
            router.handle(.cancel)
            stateContinuation.yield(isAmbientRunning ? .listening(route: source?.id.description ?? "") : .idle)
            throw EarError.notFound("no question heard")
        }
        return try await answer(question: question, trace: t)
    }

    /// Feeds a sound file through the push-to-talk tap between beginQuery() and endQuery(), as if the user were
    /// holding the button and speaking (simulator demo, tests). Takes the Mac tier like a live question.
    public func feedQuestionAudio(url: URL, realtime: Bool = false) async throws {
        let file = FileCaptureSource(url: url, realtime: realtime)
        try await file.start()
        for await f in file.frames { _ = tap.divert(f) }
    }

    /// Question from a sound file (simulator demo / harness): same ASR path as push-to-talk.
    public func askFromAudio(url: URL, at: TimeInterval? = nil) async throws -> QueryHandle {
        let t = LatencyTrace()
        t.mark(.pttDown)
        let r = try deps.makeRecognizer()
        try await r.start(locale: config.locale)
        Self.prime(r)
        let file = FileCaptureSource(url: url, realtime: false)
        try await file.start()
        for await f in file.frames { r.feed(f) }
        t.mark(.speechEnd)
        playEarcon(.listening, trace: t)
        await r.stop()
        var question = ""
        for await res in r.results where res.isFinal { question += (question.isEmpty ? "" : " ") + res.text }
        t.mark(.asrFinal)
        return try await answer(question: question, at: at, trace: t)
    }

    /// Earcon right after the question ends (P4.3, target ≤ 100 ms after speechEnd).
    private func playEarcon(_ e: Earcon, trace t: LatencyTrace? = nil) {
        guard let output = deps.output else { return }
        output.enqueue(e.chunk(sampleRate: output.sampleRate))
        t?.mark(.earcon)
    }

    /// 300 ms of silence before the question: the streaming model drops a first word that starts at sample 0
    /// ("What did…" → "Did…"); a real PTT press always has this lead-in.
    static func prime(_ r: any StreamingRecognizer) {
        for i in 0..<15 {
            r.feed(PCMFrame(samples: Array(repeating: 0, count: 320), timestamp: Double(i) * 0.02 - 0.3, source: .mic))
        }
    }

    /// Typed question (CLI, debug); trace starts at the call.
    public func ask(question: String, at: TimeInterval? = nil) async throws -> QueryHandle {
        let t = LatencyTrace()
        for s in [Stage.pttDown, .speechEnd, .asrFinal] { t.mark(s) }
        return try await answer(question: question, at: at, trace: t)
    }

    private func answer(question: String, at: TimeInterval? = nil, trace t: LatencyTrace, fallback: Bool = false)
        async throws -> QueryHandle
    {
        let intent = intents.detect(question)
        if ActionDetector.isStopListening(question) { return try await stopListening(question: question, trace: t) }
        if let minutes = ActionDetector.forgetMinutes(question) {  // §10.3: spoken purge, no approval needed
            return try await forget(minutes: minutes, question: question, trace: t)
        }
        let recent = (try? await deps.store.window(seconds: 60, before: at)) ?? []
        if let action = ActionDetector().detect(question, intent: intent, window: recent) {  // P6: no LLM for actions
            return try await actionFlow(action, question: question, intent: intent, trace: t)
        }
        let assembler = ContextAssembler(store: deps.store, embedder: deps.embedder, intents: intents)
        let ctx = try await assembler.assemble(question: question, intent: intent, at: at, tier: config.tier)
        t.mark(.contextReady)
        router.handle(.contextReady)
        var req = AnswerRequest(
            question: question, intent: intent, window: ctx.window, retrieved: ctx.retrieved,
            notes: ctx.notes, locale: config.locale, maxTokens: config.maxTokens)
        (req.windowSeconds, req.minutes, req.tier) = (ctx.windowSeconds, ctx.minutes, config.tier)
        // The query belongs to the transcript session it was asked about; a query-only session must not
        // become the store's current session (that would empty the window for every later question).
        let session: String
        if let id = sessionID ?? deps.store.currentSession {
            session = id
        } else {
            session = try await deps.store.startSession(
                SessionInfo(captureSource: "none", deviceModel: config.deviceModel), makeCurrent: false)
        }
        sessionID = session
        var vq = VoiceQuery(
            sessionID: session, question: question, intent: intent.rawValue, windowSeconds: ctx.windowSeconds,
            retrievedIDs: (ctx.window + ctx.retrieved).compactMap(\.id), tier: config.tier.rawValue,
            model: deps.answerer.name)
        vq.id = try await deps.store.save(vq)
        let (events, c) = AsyncStream.makeStream(of: AnswerEvent.self, bufferingPolicy: .unbounded)
        stateContinuation.yield(.answering(tier: config.tier.rawValue))
        let answerer = deps.answerer
        let store = deps.store
        let speaker = deps.speaker
        let output = deps.output
        let stateC = stateContinuation
        let battery = await DeviceTelemetry.batteryLevel
        Task { [weak self] in
            let sampler = FootprintSampler()
            let (sentences, sentenceC) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
            let playback = Self.play(sentences, speaker: speaker, output: output, trace: t, state: stateC)
            var text = ""
            var sawToken = false
            var sawSentence = false
            do {
                for try await e in answerer.answer(req) {
                    switch e {
                    case .token(let tok):
                        if !sawToken {
                            t.mark(.llmFirstToken)
                            sawToken = true
                        }
                        text += tok
                    case .sentence(let s):
                        if !sawSentence {
                            t.mark(.llmFirstSentence)
                            sawSentence = true
                        }
                        sentenceC.yield(s)
                    case .knowledgeTier(let k): vq.knowledgeTier = k
                    case .done(let p, let n): (vq.promptTokens, vq.completionTokens) = (p, n)
                    default: break
                    }
                    c.yield(e)
                }
            } catch {
                text += text.isEmpty ? "Sorry, I could not answer that." : ""
                if let output { output.enqueue(Earcon.fallback.chunk(sampleRate: output.sampleRate)) }
            }
            sentenceC.finish()
            await playback?.value
            t.mark(.done)
            vq.answer = PromptBuilder.parseSource(text).answer
            vq.latencyJSON = t.json(extras: [
                "thermal_state": DeviceTelemetry.thermalState, "memory_footprint_mb": sampler.finish().rounded(),
                "battery_level": battery.map { $0 as Any } ?? NSNull(), "fallback": fallback,
                "tts_engine": speaker.map { "\(type(of: $0))" } ?? "none",
            ])
            _ = try? await store.save(vq)
            c.finish()
            await self?.queryFinished(answer: vq.answer)
        }
        return QueryHandle(queryID: vq.id!, events: events, trace: t, question: question, intent: intent)
    }

    private func queryFinished(answer: String) {
        lastAnswer = answer
        router.handle(.done)
        stateContinuation.yield(isAmbientRunning ? .listening(route: source?.id.description ?? "") : .idle)
    }

    /// What the Mac delivered for one query (built by the consumer, saved once at the end).
    struct RemoteOutcome: Sendable {
        var answered = false
        var actionQuestion: String?  // an action (Mac-flagged) or a spoken command: handled on the phone
        var question = "", answer = "", knowledge = "none", intent = "", model = ""
        var promptTokens: Int?, completionTokens: Int?
    }

    /// Mac tier (P5.6): the question audio already went to the Mac while the user spoke; send query.end with the
    /// phone's recent transcript, mirror the Mac's answer and play its TTS audio. No answer.token within 3 s, an error
    /// or a disconnect → query.cancel, fallback earcon, and the phone answers from its own copy of the question.
    private func remoteAnswer(
        queryID qid: String, bridge: BridgeClient, local r: any StreamingRecognizer, trace t: LatencyTrace
    )
        async throws -> QueryHandle
    {
        let localQuestion = Task {  // finalise the local copy in parallel: needed for fallback and the record
            await r.stop()
            var q = ""
            for await res in r.results where res.isFinal { q += (q.isEmpty ? "" : " ") + res.text }
            return q
        }
        let events = await bridge.subscribe()
        let recent = (try? await deps.store.window(seconds: 300, before: nil)) ?? []
        let notes = ((try? await deps.store.pinned()) ?? []).map(\.text)
        await bridge.send(
            "query.end",
            ["query_id": qid, "window_seconds": 60, "segments": recent.map(ProtocolCodec.segmentJSON), "notes": notes])
        let session = sessionID ?? deps.store.currentSession ?? ""
        let rowID = try await deps.store.save(VoiceQuery(sessionID: session, question: "", intent: "", tier: "mac"))
        let (handleEvents, c) = AsyncStream.makeStream(of: AnswerEvent.self, bufferingPolicy: .unbounded)
        stateContinuation.yield(.answering(tier: "mac"))
        let output = deps.output
        let store = deps.store
        let timeout = config.policy.fallbackTimeout
        let gotToken = Flag()
        let consumer = Task { @Sendable () -> RemoteOutcome in
            var o = RemoteOutcome()
            c.yield(.tier("mac"))
            for await e in events {
                if Task.isCancelled { return o }
                switch e {
                case .disconnected: return o
                case .audio(_, let samples):
                    t.mark(.ttsFirstAudio)
                    t.mark(.audioOutStart)
                    output?.enqueue(AudioChunk(samples: samples, sampleRate: 24_000))
                case .message(let m) where m["query_id"]?.string == qid:
                    switch m["t"]?.string {
                    case "asr.final":
                        o.question = m["text"]?.string ?? ""
                        t.mark(.asrFinal)
                        if ActionDetector.isStopListening(o.question) || ActionDetector.forgetMinutes(o.question) != nil
                        {
                            o.actionQuestion = o.question  // spoken commands act on the phone, not via the Mac's LLM
                            return o
                        }
                    case "answer.token":
                        if gotToken.setFirst() { t.mark(.llmFirstToken) }
                        o.answer += m["text"]?.string ?? ""
                        c.yield(.token(m["text"]?.string ?? ""))
                    case "answer.sentence":
                        t.mark(.llmFirstSentence)
                        c.yield(.sentence(m["text"]?.string ?? ""))
                    case "answer.done":
                        (o.knowledge, o.intent) = (m["knowledge_tier"]?.string ?? "none", m["intent"]?.string ?? "")
                        o.model = "mac:" + (m["model"]?.string ?? "")
                        o.promptTokens = m["prompt_tokens"]?.number.map(Int.init)
                        o.completionTokens = m["completion_tokens"]?.number.map(Int.init)
                        c.yield(.knowledgeTier(o.knowledge))
                        c.yield(.done(promptTokens: o.promptTokens ?? 0, completionTokens: o.completionTokens ?? 0))
                        o.answered = true
                        return o
                    case "answer.action":
                        o.actionQuestion = m["action"]?.object?["question"]?.string
                        return o
                    case "error": return o
                    default: break
                    }
                default: break
                }
            }
            return o
        }
        let timer = Task { @Sendable in
            try? await Task.sleep(for: .seconds(timeout))
            if !gotToken.isSet { consumer.cancel() }
        }
        Task { [weak self] in
            let o = await consumer.value
            timer.cancel()
            if o.answered {
                while output?.isPlaying == true { try? await Task.sleep(for: .milliseconds(20)) }
                t.mark(.audioOutEnd)
                t.mark(.done)
                var vq = VoiceQuery(
                    sessionID: session, question: o.question, intent: o.intent, tier: "mac",
                    knowledgeTier: o.knowledge, model: o.model)
                vq.id = rowID
                vq.answer = PromptBuilder.parseSource(o.answer).answer
                (vq.promptTokens, vq.completionTokens) = (o.promptTokens, o.completionTokens)
                vq.latencyJSON = t.json(extras: ["fallback": false])
                _ = try? await store.save(vq)
                c.finish()
                await self?.queryFinished(answer: vq.answer)
                return
            }
            if let q = o.actionQuestion {  // ADR-018: run the action flow locally with the Mac's question text
                await bridge.send("query.cancel", ["query_id": qid])  // a command: stop the Mac's LLM
                try? await store.db.write {
                    try $0.execute(sql: "DELETE FROM voice_queries WHERE id = ?", arguments: [rowID])
                }
                if let local = try? await self?.answer(question: q, trace: t) {
                    for await e in local.events { c.yield(e) }
                }
                c.finish()
                return
            }
            // Fallback: stop the Mac, signal it, answer on the phone (its own row, tier "phone", fallback true).
            await bridge.send("query.cancel", ["query_id": qid])
            if let output { output.enqueue(Earcon.fallback.chunk(sampleRate: output.sampleRate)) }
            try? await store.db.write {
                try $0.execute(sql: "DELETE FROM voice_queries WHERE id = ?", arguments: [rowID])
            }
            let q = await localQuestion.value
            if !q.isEmpty, let local = try? await self?.answer(question: q, trace: t, fallback: true) {
                for await e in local.events { c.yield(e) }
            }
            c.finish()
        }
        return QueryHandle(queryID: rowID, events: handleEvents, trace: t, question: "", intent: .freeform)
    }

    // MARK: actions with spoken approval (P6.1–P6.3)

    private func actionFlow(_ action: EarAction, question: String, intent: Intent, trace t: LatencyTrace) async throws
        -> QueryHandle
    {
        t.mark(.contextReady)
        let session = sessionID ?? deps.store.currentSession ?? ""
        var vq = VoiceQuery(
            sessionID: session, question: question, intent: intent.rawValue, tier: "phone", model: "actions")
        vq.actionProposed = action.json
        vq.id = try await deps.store.save(vq)
        let (events, c) = AsyncStream.makeStream(of: AnswerEvent.self, bufferingPolicy: .unbounded)
        let executor = deps.executor ?? EarActionExecutor(store: deps.store)
        stateContinuation.yield(.awaitingApproval(action))
        c.yield(.tier("phone"))
        c.yield(.proposedAction(action))
        Task { [weak self] in
            guard let self else { return }
            var spoken: [String] = []
            // ADR-021: with web search switched on, a search runs at once, with no spoken "yes"
            let outcome: ApprovalOutcome =
                if case .webSearch = action { .accepted(action) } else {
                    await ApprovalGate().run(
                        action,
                        speak: { text in
                            c.yield(.sentence(text))
                            await self.say(text, trace: t)
                        },
                        listen: { seconds in await self.listen(seconds: seconds) })
                }
            if case .webSearch = action {} else { spoken.append(action.proposal) }
            var result: String
            switch outcome {
            case .accepted(let a), .edited(let a):
                do { result = try await executor.execute(a) } catch { result = "Sorry, that did not work: \(error)" }
                if case .edited(let a) = outcome { vq.actionProposed = a.json }
            case .dismissed: result = "Okay, I won't."
            case .timeout: result = "I didn't hear a yes, so I won't."
            }
            c.yield(.sentence(result))
            await self.say(result, trace: t)
            spoken.append(result)
            t.mark(.done)
            vq.answer = spoken.joined(separator: " ")
            vq.actionResponse = outcome.response
            vq.latencyJSON = t.json(extras: ["action": true])
            _ = try? await self.deps.store.save(vq)
            c.yield(.done(promptTokens: 0, completionTokens: 0))
            c.finish()
            await self.queryFinished(answer: result)
        }
        return QueryHandle(queryID: vq.id!, events: events, trace: t, question: question, intent: intent)
    }

    private func forget(minutes: Int, question: String, trace t: LatencyTrace) async throws -> QueryHandle {
        let n = try await deps.store.purge(lastSeconds: Double(minutes) * 60)
        let line = "Forgot the last \(minutes) minutes, \(n) segment\(n == 1 ? "" : "s")."
        var vq = VoiceQuery(
            sessionID: sessionID ?? deps.store.currentSession ?? "", question: "(purge)", intent: "purge",
            answer: line, model: "none")  // the question text is not kept: it may name what was forgotten
        vq.latencyJSON = t.json(extras: ["purge_minutes": minutes])
        vq.id = try await deps.store.save(vq)
        let (events, c) = AsyncStream.makeStream(of: AnswerEvent.self)
        c.yield(.sentence(line))
        Task { [weak self] in
            await self?.say(line, trace: t)
            c.yield(.done(promptTokens: 0, completionTokens: 0))
            c.finish()
            await self?.queryFinished(answer: line)
        }
        return QueryHandle(queryID: vq.id!, events: events, trace: t, question: question, intent: .freeform)
    }

    /// Spoken "stop listening": confirm, then stop the ambient capture (the app follows the .idle state).
    private func stopListening(question: String, trace t: LatencyTrace) async throws -> QueryHandle {
        let line = "Stopped listening."
        var vq = VoiceQuery(
            sessionID: sessionID ?? deps.store.currentSession ?? "", question: question, intent: "command",
            answer: line, model: "none")
        vq.latencyJSON = t.json()
        vq.id = try await deps.store.save(vq)
        let (events, c) = AsyncStream.makeStream(of: AnswerEvent.self)
        c.yield(.sentence(line))
        Task { [weak self] in
            await self?.say(line, trace: t)
            await self?.queryFinished(answer: line)
            await self?.stopAmbient()
            c.yield(.done(promptTokens: 0, completionTokens: 0))
            c.finish()
        }
        return QueryHandle(queryID: vq.id!, events: events, trace: t, question: question, intent: .freeform)
    }

    /// Speaks one line through the TTS path (no-op without speaker/output, e.g. in tests).
    func say(_ text: String, trace t: LatencyTrace) async {
        let (s, c) = AsyncStream.makeStream(of: String.self)
        c.yield(text)
        c.finish()
        await Self.play(s, speaker: deps.speaker, output: deps.output, trace: t, state: stateContinuation)?.value
    }

    /// Listens for a short reply: the capture source's frames go to a fresh recognizer for `seconds`, unless the app
    /// (on-screen Yes/No) or a test answers first through `respondToApproval`.
    func listen(seconds: TimeInterval) async -> String? {
        if let early = earlyReply {
            earlyReply = nil
            return early
        }
        let (stream, c) = AsyncStream.makeStream(of: String?.self, bufferingPolicy: .bufferingNewest(1))
        replyContinuation = c
        defer { replyContinuation = nil }
        if isAmbientRunning, let r = try? deps.makeRecognizer() {
            try? await r.start(locale: config.locale)
            Self.prime(r)
            tap.set(r)
        }
        let tap = tap
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard let r = tap.take() else {
                c.yield(nil)
                return
            }
            await r.stop()
            var text = ""
            for await res in r.results where res.isFinal { text += (text.isEmpty ? "" : " ") + res.text }
            c.yield(text.isEmpty ? nil : text)
        }
        var reply: String?? = nil
        for await r in stream {
            reply = r
            break
        }
        timer.cancel()
        if let r = tap.take() { Task { await r.stop() } }  // an on-screen answer came first
        return reply ?? nil
    }

    /// On-screen (or test) answer to the pending approval: "yes", "no", "change it to Friday at 3"…
    public func respondToApproval(_ text: String) {
        if let c = replyContinuation { c.yield(text) } else { earlyReply = text }
    }

    /// Sentences → speaker → output; marks ttsFirstAudio/audioOutStart/audioOutEnd. nil without TTS deps.
    static func play(
        _ sentences: AsyncStream<String>, speaker: (any Speaker)?, output: AudioOutput?, trace t: LatencyTrace,
        state: AsyncStream<PipelineState>.Continuation
    ) -> Task<Void, Never>? {
        guard let speaker, let output else { return nil }
        return Task {
            var first = true
            for await chunk in speaker.speak(sentences: sentences) {
                if first {
                    t.mark(.ttsFirstAudio)
                    state.yield(.speaking)
                    first = false
                }
                output.enqueue(chunk)
                t.mark(.audioOutStart)  // first mark wins: the player starts as soon as audio is queued
            }
            while output.isPlaying { try? await Task.sleep(for: .milliseconds(20)) }
            if !first { t.mark(.audioOutEnd) }
        }
    }

    /// Stops generation and speech now (second stem press, cancel button).
    public func cancelSpeech() async {
        deps.answerer.cancel()
        deps.speaker?.stop()
        deps.output?.stop()
        router.handle(.cancel)
    }

    /// "Say again": speaks the last answer without a new model call (P4.4).
    public func repeatLastAnswer() async {
        guard let text = lastAnswer, !text.isEmpty else { return }
        var splitter = SentenceSplitter(minWords: 1)
        let (sentences, c) = AsyncStream.makeStream(of: String.self)
        for s in splitter.push(text + " ") { c.yield(s) }
        if let rest = splitter.flush() { c.yield(rest) }
        c.finish()
        await Self.play(
            sentences, speaker: deps.speaker, output: deps.output, trace: LatencyTrace(), state: stateContinuation)?
            .value
    }
}
