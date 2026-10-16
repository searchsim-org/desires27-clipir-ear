import XCTest

@testable import EarCore

final class IntentDetectorTests: XCTestCase {
    let d = IntentDetector()

    func testEveryRuleMatchesItsExamples() {
        let cases: [(String, Intent)] = [
            ("What did the speaker just say?", .explainLast), ("what did she say", .explainLast),
            ("Repeat that please", .explainLast), ("say that again", .explainLast), ("what was that", .explainLast),
            ("Expand on that", .expand), ("tell me more", .expand), ("explain that", .expand),
            ("What does that mean?", .expand), ("more about this", .expand),
            ("What did I miss?", .summarizeWindow), ("Summarize the last five minutes", .summarizeWindow),
            ("give me a recap", .summarizeWindow), ("catch me up", .summarizeWindow),
            ("Who said that the deadline moved?", .whoSaid), ("who proposed the budget cut", .whoSaid),
            ("Translate that into French", .translate), ("what does gracias mean in English", .translate),
            ("note this", .noteThis), ("remember that", .noteThis), ("clip this", .noteThis),
            ("Remind me to email Anna tomorrow", .remindMe),
            ("search the web for zipformer", .searchWeb), ("look it up online", .searchWeb),
            ("Is the exam open book?", .freeform),
        ]
        for (q, want) in cases { XCTAssertEqual(d.detect(q), want, q) }
    }

    func testMinutesParsing() {
        XCTAssertEqual(d.minutes(in: "summarize the last 3 minutes"), 3)
        XCTAssertEqual(d.minutes(in: "what did I miss in the last two minutes?"), 2)
        XCTAssertNil(d.minutes(in: "what did I miss?"))
    }
}

final class RetrievalTests: XCTestCase {
    private func store(_ texts: [(Double, String)]) async throws -> SQLiteTranscriptStore {
        let s = try SQLiteTranscriptStore.inMemory()
        let session = try await s.startSession(SessionInfo(captureSource: "t"))
        for (t, text) in texts {
            _ = try await s.append(Segment(sessionID: session, t0: t, t1: t + 4, text: text, source: "t", engine: "t"))
        }
        return s
    }

    func testPlantedFactOutsideWindowIsRetrievedAndDeduped() async throws {
        let s = try await store([
            (10, "The optimizer we use is called Adam"), (400, "Let us talk about stability"),
            (430, "Clipping keeps gradients bounded"),
        ])
        let ctx = try await ContextAssembler(store: s, embedder: HashEmbedder()).assemble(
            question: "tell me more about the optimizer", intent: .expand, at: nil)
        XCTAssertTrue(ctx.window.allSatisfy { $0.t1 > 434 - 180 })
        XCTAssertEqual(ctx.retrieved.first?.text, "The optimizer we use is called Adam")
        XCTAssertEqual(Set(ctx.retrieved.compactMap(\.id)).count, ctx.retrieved.count)
        XCTAssertTrue(Set(ctx.retrieved.compactMap(\.id)).isDisjoint(with: ctx.window.compactMap(\.id)))
    }

    func testExplainLastUsesWindowOnlyAndHonoursAt() async throws {
        let s = try await store([(10, "first point"), (70, "second point"), (200, "future point")])
        let ctx = try await ContextAssembler(store: s).assemble(
            question: "what did the speaker just say", intent: .explainLast, at: 75)
        XCTAssertEqual(ctx.window.map(\.text), ["second point"])
        XCTAssertTrue(ctx.retrieved.isEmpty)
    }

    func testBudgetNeverExceeded() async throws {
        let long = String(repeating: "word ", count: 300)  // ≈ 375 tokens each
        let s = try await store((0..<20).map { (Double($0) * 5, "\(long) \($0)") })
        let ctx = try await ContextAssembler(store: s, embedder: HashEmbedder()).assemble(
            question: "word", intent: .whoSaid, at: nil)
        let tokens = ContextAssembler.tokens((ctx.window + ctx.retrieved).map(\.text).joined(separator: "\n"))
        XCTAssertLessThanOrEqual(tokens + 300, 2000)
        XCTAssertLessThanOrEqual(ContextAssembler.tokens(ctx.window.map(\.text).joined(separator: "\n")), 1200)
    }
}

final class PromptBuilderTests: XCTestCase {
    func testExplainLastGoldenPrompt() {
        var req = AnswerRequest(
            question: "What did the speaker just say?", intent: .explainLast,
            window: [Segment(sessionID: "s", t0: 0, t1: 2, text: "The optimizer is Adam", source: "t", engine: "t")],
            retrieved: [], notes: [])
        req.windowSeconds = 60
        XCTAssertEqual(
            PromptBuilder.user(req),
            "TRANSCRIPT (last 60s, newest last):\n[unknown] The optimizer is Adam\n\nQUESTION: What did the speaker just say?"
        )
        let sys = PromptBuilder.system(req)
        XCTAssertTrue(sys.hasPrefix("You are a private assistant whispering into the user's ear. Answer in English."))
        XCTAssertTrue(sys.contains("Total ≤ 80 words"))
        XCTAssertTrue(sys.hasSuffix("SOURCE: transcript | notes | general | none"))
    }

    func testSourceParsing() {
        XCTAssertEqual(PromptBuilder.parseSource("It is Adam.\nSOURCE: transcript").tier, "transcript")
        XCTAssertEqual(PromptBuilder.parseSource("It is Adam.\nSOURCE: transcript").answer, "It is Adam.")
        XCTAssertEqual(PromptBuilder.parseSource("No source line").tier, "none")
        XCTAssertEqual(PromptBuilder.parseSource("x\nsource: GENERAL").tier, "general")
        XCTAssertEqual(PromptBuilder.parseSource("x\nSOURCE: banana").tier, "none")
    }

    /// The answer card shows the text while it streams; the SOURCE line, even half-arrived, never shows.
    func testStreamingTextHidesTheSourceLine() {
        XCTAssertEqual(PromptBuilder.visibleWhileStreaming("It is Adam."), "It is Adam.")
        XCTAssertEqual(PromptBuilder.visibleWhileStreaming("It is Adam.\nSOURCE: transcript | notes"), "It is Adam.")
        XCTAssertEqual(PromptBuilder.visibleWhileStreaming("It is Adam.\nSOU"), "It is Adam.")
        XCTAssertEqual(PromptBuilder.visibleWhileStreaming("It is Adam.\n"), "It is Adam.")
        XCTAssertEqual(PromptBuilder.visibleWhileStreaming("It is Adam. source: general"), "It is Adam.")
        XCTAssertEqual(PromptBuilder.visibleWhileStreaming("Sounds of the river"), "Sounds of the river")
    }
}

final class SentenceSplitterTests: XCTestCase {
    func testBoundariesAbbreviationsAndMinimumLength() {
        var s = SentenceSplitter()
        var out: [String] = []
        for tok in [
            "The speaker said the deadline", " moves to Friday. ", "Dr. Smith agreed, e.g. ",
            "on the call today. Yes. ",
            "That was all.\nSOURCE: transcript",
        ] {
            out += s.push(tok)
        }
        if let rest = s.flush() { out.append(rest) }
        XCTAssertEqual(
            out,
            [
                "The speaker said the deadline moves to Friday.", "Dr. Smith agreed, e.g. on the call today.",
                "Yes. That was all.",
            ])
    }
    /// Kokoro cannot start mid-sentence (ADR-020): the first spoken chunk may end at a comma after 4 words.
    func testFirstClauseEndsEarlyOnlyOnce() {
        var s = SentenceSplitter(firstClause: true)
        var out = s.push(
            "The speaker said the bridge, built in eleven forty, still stands. It has seven arches, all stone. ")
        if let rest = s.flush() { out.append(rest) }
        XCTAssertEqual(
            out,
            ["The speaker said the bridge,", "built in eleven forty, still stands.", "It has seven arches, all stone."])
    }

    func testFirstClauseNeedsFourWords() {
        var s = SentenceSplitter(firstClause: true)
        XCTAssertEqual(
            s.push("Yes, the speaker said the bridge still stands today. "),
            [
                "Yes, the speaker said the bridge still stands today."
            ])
    }
}

final class QueryRouterTests: XCTestCase {
    func testHappyPathCancelAndBargeIn() {
        var r = QueryRouter()
        for e: QueryRouter.Event in [.pttDown, .pttUp, .asrFinal, .contextReady, .firstSentence] {
            XCTAssertTrue(r.handle(e))
        }
        XCTAssertEqual(r.state, .speaking)
        XCTAssertTrue(r.handle(.pttDown))  // barge-in while speaking
        XCTAssertEqual(r.state, .capturingQuestion)
        XCTAssertFalse(r.handle(.contextReady))  // illegal: keeps state
        XCTAssertEqual(r.state, .capturingQuestion)
        XCTAssertTrue(r.handle(.cancel))
        XCTAssertEqual(r.state, .idle)
    }
}

final class EarPipelineTests: XCTestCase {
    func testAmbientThenTypedQuestionPersistsVoiceQueryWithTrace() async throws {
        let store = try SQLiteTranscriptStore.inMemory()
        let lines = Mutex2(["The deadline moves to Friday", "Lunch is at noon"])
        let deps = PipelineDeps(
            store: store, makeSource: { ToneSource(pattern: [true, false, true]) }, makeVAD: { EnergyVAD() },
            makeRecognizer: { ScriptedRecognizer(lines: lines.take()) },
            answerer: MockAnswerer { req in
                "You heard: \(req.window.last?.text ?? "nothing") today.\nSOURCE: transcript"
            })
        let p = EarPipeline(config: PipelineConfig(), deps: deps)
        try await p.startAmbient()
        await p.waitUntilAmbientEnds()  // finite source: let it play out
        let h = try await p.ask(question: "What did the speaker just say?")
        var spoken: [String] = []
        for await e in h.events { if case .sentence(let s) = e { spoken.append(s) } }
        XCTAssertEqual(spoken, ["You heard: Lunch is at noon today."])
        XCTAssertEqual(h.intent, .explainLast)
        try await Task.sleep(for: .milliseconds(100))
        let q = try await store.queries().first!
        XCTAssertEqual(q.knowledgeTier, "transcript")
        XCTAssertEqual(q.answer, "You heard: Lunch is at noon today.")
        let latency = try JSONSerialization.jsonObject(with: Data(q.latencyJSON.utf8)) as! [String: Any]
        let stages = ["pttDown", "contextReady", "llmFirstToken", "llmFirstSentence", "done"]
        let times = stages.compactMap { latency[$0] as? Double }
        XCTAssertEqual(times.count, stages.count)
        XCTAssertEqual(times, times.sorted())
        XCTAssertNotNil(latency["thermal_state"] as? String)
        XCTAssertNotNil(latency["memory_footprint_mb"] as? Double)
    }
}

/// Hands out the scripted lines once (first recognizer = ambient), then nothing (query recognizers).
final class Mutex2: @unchecked Sendable {
    private var lines: [String]
    private let lock = NSLock()
    init(_ l: [String]) { lines = l }
    func take() -> [String] {
        lock.withLock {
            defer { lines = [] }
            return lines
        }
    }
}

final class LlamaAnswererTests: XCTestCase {
    /// HANDOVER P3: Gemma 4 E2B ≥ 8/10 explainLast on lecture_en_01; TinyAnswerer ≥ 5/10 (sanity). Slow, real models.
    func testGroundedAccuracyOnLecture01() async throws {
        let (_, segments) = try await ASRIntegrationTests.transcribe("lecture_en_01")
        let facts = try Fixtures.facts("lecture_en_01")
        for (name, minimum, answerer) in [
            ("gemma", 8, LlamaAnswerer(modelPath: try loadOrSkip { try Models.path(Models.gemma4E2B) })),
            ("tiny", 5, try loadOrSkip { try LlamaAnswerer.tiny() }),
        ] {
            let store = try SQLiteTranscriptStore.inMemory()
            let session = try await store.startSession(SessionInfo(captureSource: "file"))
            for var s in segments {
                s.id = nil
                s.sessionID = session
                _ = try await store.append(s)
            }
            let p = EarPipeline(
                config: PipelineConfig(),
                deps: PipelineDeps(
                    store: store, makeSource: { throw EarError.cancelled },
                    makeVAD: { EnergyVAD() }, makeRecognizer: { ScriptedRecognizer(lines: []) }, answerer: answerer))
            var correct = 0
            for f in facts {
                let h = try await p.ask(question: f.question, at: f.t + 5)
                var text = ""
                for await e in h.events { if case .token(let t) = e { text += t } }
                if f.mustContain.contains(where: { text.lowercased().contains($0.lowercased()) }) { correct += 1 }
            }
            answerer.unload()
            print("LlamaAnswerer \(name): \(correct)/\(facts.count)")
            XCTAssertGreaterThanOrEqual(correct, minimum, name)
        }
    }
}

final class LlamaEmbedderTests: XCTestCase {
    func testNomicEmbeddingsAreUnitLengthAndSemantic() async throws {
        let e = try loadOrSkip { try LlamaEmbedder() }
        let q = try await e.embed("search_query: which optimizer did they use")
        let near = try await e.embed("search_document: The optimizer we use is called Adam")
        let far = try await e.embed("search_document: The field trip is on Wednesday morning")
        XCTAssertEqual(q.count, 768)
        XCTAssertEqual(q.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-3)
        XCTAssertGreaterThan(SQLiteTranscriptStore.cosine(q, near), SQLiteTranscriptStore.cosine(q, far))
    }
}
