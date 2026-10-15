import GRDB
import XCTest

@testable import EarCore

final class ActionDetectionTests: XCTestCase {
    // Wednesday 2026-10-14 10:00 local
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 10))!
    var d: ActionDetector {
        let n = now
        return ActionDetector(now: { n })
    }

    func testReminderWithSpelledTime() throws {
        // NSDataDetector resolves "tomorrow" against the real clock (it takes no reference date), so use today here.
        guard
            case .reminder(let text, let at)? = ActionDetector().detect(
                "remind me to email Anna tomorrow at nine", intent: .remindMe, window: [])
        else { return XCTFail() }
        XCTAssertEqual(text, "email Anna")
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let c = Calendar.current.dateComponents([.day, .hour], from: try XCTUnwrap(at))
        XCTAssertEqual(c.day, Calendar.current.component(.day, from: tomorrow))
        XCTAssertEqual(c.hour, 9)
    }

    func testNoteFromQuoteColonOrWindow() {
        XCTAssertEqual(
            d.detect("note this \"the exam is open book\"", intent: .noteThis, window: []),
            .note(text: "the exam is open book"))
        XCTAssertEqual(
            d.detect("note this: lab moves to Hamilton", intent: .noteThis, window: []),
            .note(text: "lab moves to Hamilton"))
        let w = [
            Segment(sessionID: "s", t0: 0, t1: 5, text: "old", source: "t", engine: "t"),
            Segment(sessionID: "s", t0: 40, t1: 50, text: "The deadline moves to Friday", source: "t", engine: "t"),
        ]
        XCTAssertEqual(d.detect("note that", intent: .noteThis, window: w), .note(text: "The deadline moves to Friday"))
    }

    func testCalendarPinAndWebSearch() {
        guard
            case .calendar(let title, let start, let end)? = d.detect(
                "put a meeting with the client in my calendar on Friday at 3pm", intent: .freeform, window: [])
        else { return XCTFail() }
        XCTAssertTrue(title.contains("client"), title)
        XCTAssertEqual(Calendar.current.component(.hour, from: start), 15)
        XCTAssertEqual(end.timeIntervalSince(start), 3600)
        XCTAssertEqual(d.detect("pin the last five minutes", intent: .freeform, window: []), .pinWindow(seconds: 300))
        XCTAssertEqual(
            d.detect("search the web for zipformer", intent: .searchWeb, window: []), .webSearch(query: "zipformer"))
        XCTAssertNil(d.detect("what did the speaker just say", intent: .explainLast, window: []))
    }
}

final class ForgetCommandTests: XCTestCase {
    func testSpokenForgetPurgesTheLastMinutes() async throws {
        XCTAssertEqual(ActionDetector.forgetMinutes("forget the last ten minutes"), 10)
        XCTAssertEqual(ActionDetector.forgetMinutes("please delete the last 5 minutes"), 5)
        XCTAssertNil(ActionDetector.forgetMinutes("what did I miss in the last ten minutes"))
        let store = try SQLiteTranscriptStore.inMemory()
        let session = try await store.startSession(SessionInfo(captureSource: "t"))
        _ = try await store.append(
            Segment(sessionID: session, t0: 0, t1: 3, text: "keep", source: "t", engine: "t", pinned: false))
        let p = EarPipeline(
            config: PipelineConfig(),
            deps: PipelineDeps(
                store: store, makeSource: { throw EarError.cancelled },
                makeVAD: { EnergyVAD() }, makeRecognizer: { ScriptedRecognizer(lines: []) }, answerer: MockAnswerer()))
        let h = try await p.ask(question: "forget the last ten minutes")
        var spoken: [String] = []
        for await e in h.events { if case .sentence(let s) = e { spoken.append(s) } }
        XCTAssertEqual(spoken, ["Forgot the last 10 minutes, 1 segment."])
        let left = try await store.count()
        XCTAssertEqual(left, 0)
    }
}

final class StopListeningCommandTests: XCTestCase {
    func testSpokenStopListeningStopsTheAmbientCapture() async throws {
        XCTAssertTrue(ActionDetector.isStopListening("stop listening"))
        XCTAssertTrue(ActionDetector.isStopListening("Please stop listening now."))
        XCTAssertTrue(ActionDetector.isStopListening("pause listening"))
        XCTAssertFalse(ActionDetector.isStopListening("when did they stop listening to the radio"))
        let wav = try TestAudio.writeWav(seconds: 20)
        let p = EarPipeline(
            config: PipelineConfig(),
            deps: PipelineDeps(
                store: try SQLiteTranscriptStore.inMemory(),
                makeSource: { FileCaptureSource(url: wav, realtime: true) },
                makeVAD: { EnergyVAD() }, makeRecognizer: { ScriptedRecognizer(lines: []) },
                answerer: MockAnswerer { _ in "I will stop." }))
        try await p.startAmbient()
        let h = try await p.ask(question: "stop listening")
        var spoken: [String] = []
        for await e in h.events { if case .sentence(let s) = e { spoken.append(s) } }
        XCTAssertEqual(spoken, ["Stopped listening."])
        let running = await p.isAmbientRunning
        XCTAssertFalse(running, "capture still running after the spoken command")
    }
}

final class ApprovalGateTests: XCTestCase {
    let reminder = EarAction.reminder(
        text: "email Anna", at: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9)))

    private func run(_ replies: [String?]) async -> ApprovalOutcome {
        let queue = ReplyQueue(replies)
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 10))!
        return await ApprovalGate(now: { now }).run(reminder, speak: { _ in }, listen: { _ in queue.next() })
    }

    func testYesNoSilenceChangeAndLateCancel() async {
        let accepted = await run(["yes", nil])
        XCTAssertEqual(accepted, .accepted(reminder))
        let no = await run(["no thanks"])
        XCTAssertEqual(no, .dismissed)
        let silence = await run([nil])
        XCTAssertEqual(silence, .timeout)
        let late = await run(["yes", "cancel"])
        XCTAssertEqual(late, .dismissed, "2 s cancel window")
        guard case .edited(.reminder(let text, let at)) = await run(["change it to Friday"]) else { return XCTFail() }
        XCTAssertEqual(text, "email Anna")
        let c = Calendar.current.dateComponents([.weekday, .hour], from: at!)
        XCTAssertEqual(c.weekday, 6)  // Friday
        XCTAssertEqual(c.hour, 9, "a bare day keeps the time")
    }
}

final class ReplyQueue: @unchecked Sendable {
    private var items: [String?]
    private let lock = NSLock()
    init(_ i: [String?]) { items = i }
    func next() -> String? { lock.withLock { items.isEmpty ? nil : items.removeFirst() } }
}

final class FakeEvents: EventStoring, @unchecked Sendable {
    var reminders: [(String, Date?)] = [], events: [(String, Date, Date)] = []
    func requestAccess(toReminders: Bool) async throws -> Bool { true }
    func addReminder(title: String, due: Date?) throws { reminders.append((title, due)) }
    func addEvent(title: String, start: Date, end: Date) throws { events.append((title, start, end)) }
}

final class ActionPipelineTests: XCTestCase {
    private func pipeline(_ store: SQLiteTranscriptStore, _ events: FakeEvents) -> EarPipeline {
        EarPipeline(
            config: PipelineConfig(),
            deps: PipelineDeps(
                store: store, makeSource: { throw EarError.cancelled }, makeVAD: { EnergyVAD() },
                makeRecognizer: { ScriptedRecognizer(lines: []) }, answerer: MockAnswerer(),
                executor: EarActionExecutor(store: store, events: events)))
    }

    func testReminderApprovedByYesIsCreatedAndLogged() async throws {
        let store = try SQLiteTranscriptStore.inMemory()
        _ = try await store.startSession(SessionInfo(captureSource: "t"))
        let events = FakeEvents()
        let p = pipeline(store, events)
        let h = try await p.ask(question: "Remind me to email Anna tomorrow at nine")
        await p.respondToApproval("yes")
        var spoken: [String] = []
        var proposed: EarAction?
        for await e in h.events {
            if case .sentence(let s) = e { spoken.append(s) }
            if case .proposedAction(let a) = e { proposed = a }
        }
        try await Task.sleep(for: .milliseconds(100))
        guard case .reminder(let text, _)? = proposed else { return XCTFail() }
        XCTAssertEqual(text, "email Anna")
        XCTAssertTrue(spoken.first!.hasPrefix("Create a reminder to email Anna"))
        XCTAssertEqual(spoken.last, "Reminder created.")
        XCTAssertEqual(events.reminders.map(\.0), ["email Anna"])
        let q = try await store.queries().last!
        XCTAssertEqual(q.actionResponse, "accepted")
        XCTAssertTrue(q.actionProposed!.contains("email Anna"))
    }

    func testNoCreatesNothingAndNoteLandsInNotes() async throws {
        let store = try SQLiteTranscriptStore.inMemory()
        let session = try await store.startSession(SessionInfo(captureSource: "t"))
        _ = try await store.append(
            Segment(sessionID: session, t0: 0, t1: 4, text: "The exam is open book", source: "t", engine: "t"))
        let events = FakeEvents()
        let p = pipeline(store, events)
        let h1 = try await p.ask(question: "remind me to call the lab at five")
        await p.respondToApproval("no")
        for await _ in h1.events {}
        XCTAssertTrue(events.reminders.isEmpty)
        let h2 = try await p.ask(question: "note this")
        await p.respondToApproval("yes")
        for await _ in h2.events {}
        let notes = try await store.notes()
        XCTAssertEqual(notes.map(\.text), ["The exam is open book"])
        let responses = try await store.queries().map(\.actionResponse)
        XCTAssertEqual(responses, ["dismissed", "accepted"])
    }
}

final class ExporterTests: XCTestCase {
    private func populated() async throws -> (SQLiteTranscriptStore, String) {
        let store = try SQLiteTranscriptStore.inMemory()
        let session = try await store.startSession(SessionInfo(captureSource: "mic"))
        _ = try await store.append(
            Segment(sessionID: session, t0: 0, t1: 4, text: "SECRET TRANSCRIPT LINE", source: "mic", engine: "t"))
        var q = VoiceQuery(
            sessionID: session, question: "SECRET QUESTION", intent: "explainLast", answer: "SECRET ANSWER",
            tier: "mac", knowledgeTier: "transcript", model: "m",
            latencyJSON: #"{"speechEnd":1,"audioOutStart":2.2,"llmFirstToken":1.6}"#)
        q.actionResponse = "accepted"
        try await store.save(q)
        _ = try await store.purge(lastSeconds: 1)
        return (store, session)
    }

    func testDefaultExportHasMeasuresOnlyAndNoText() async throws {
        let (store, session) = try await populated()
        let doc = try await Exporter(store: store).export(session: session)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: doc), as: UTF8.self)
        XCTAssertFalse(text.contains("SECRET"), "no transcript, question or answer text by default")
        let m = doc["measures"] as! [String: Any]
        XCTAssertEqual(m["query_count"] as? Int, 1)
        XCTAssertEqual(m["tier_split"] as? [String: Int], ["mac": 1])
        XCTAssertEqual(m["latency_first_audio_p50"] as? Double ?? 0, 1.2, accuracy: 1e-9)
        XCTAssertEqual(m["action_acceptance_rate"] as? Double, 1.0)
        XCTAssertEqual(m["purge_count"] as? Int, 1)
        XCTAssertEqual(doc["export_schema_version"] as? Int, 2)
        XCTAssertNil(doc["transcript"])
        XCTAssertNil(doc["queries"])
    }

    /// P8.7: the study's analysis scripts read these keys; changing them means bumping export_schema_version.
    func testExportSchemaSnapshot() async throws {
        let (store, session) = try await populated()
        let doc = try await Exporter(store: store).export(session: session)
        XCTAssertEqual(
            doc.keys.sorted(),
            ["app_version", "device_metrics", "export_schema_version", "exported_at", "measures", "session"])
        XCTAssertEqual(
            (doc["measures"] as! [String: Any]).keys.sorted(),
            [
                "action_acceptance_rate", "action_responses", "audio_retained_segments", "battery_drop", "cue_count",
                "fallbacks", "latency_first_audio_p50", "latency_first_audio_p95", "latency_first_token_p50",
                "memory_footprint_mb_max", "purge_count", "purged_segments", "queries_by_intent", "query_count",
                "thermal_states", "tier_split",
            ])
        XCTAssertEqual(
            (doc["session"] as! [String: Any]).keys.sorted(),
            ["capture_source", "ended_at", "id", "mode", "retention_seconds", "started_at", "tier_policy"])
        XCTAssertEqual(
            (doc["device_metrics"] as! [String: Any]).keys.sorted(),
            ["cpu_seconds", "crashes", "hangs", "payloads", "peak_memory_mb"])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: doc))
    }

    func testOptInIncludesQuestionsAndTranscriptAndFilesAreWritten() async throws {
        let (store, session) = try await populated()
        let doc = try await Exporter(store: store).export(
            session: session, options: .init(includeQuestionsAndAnswers: true, includeTranscript: true))
        XCTAssertEqual((doc["queries"] as! [[String: Any]]).first?["question"] as? String, "SECRET QUESTION")
        XCTAssertNotNil(doc["transcript"])
        let files = try await Exporter(store: store).write(session: session)
        XCTAssertEqual(files.map(\.pathExtension), ["json", "md"])
        XCTAssertFalse(try String(contentsOf: files[0], encoding: .utf8).contains("SECRET"))
    }
}
