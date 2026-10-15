import EventKit
import XCTest

@testable import EarCore

/// P6 simulator smoke test: "remind me to email Anna tomorrow at nine" → proposal → "yes" → a real reminder in the
/// simulator's Reminders store at 9:00 tomorrow (EventKit; make test grants the permission).
final class ActionSmokeTest: XCTestCase {
    func testSpokenReminderIsCreatedAfterYes() async throws {
        let ek = EKEventStore()
        guard (try? await ek.requestFullAccessToReminders()) == true else {
            throw XCTSkip("reminders permission not granted")
        }
        let store = try SQLiteTranscriptStore.inMemory()
        _ = try await store.startSession(SessionInfo(captureSource: "t", deviceModel: "EarSim"))
        let p = EarPipeline(
            config: PipelineConfig(),
            deps: PipelineDeps(
                store: store, makeSource: { throw EarError.cancelled }, makeVAD: { EnergyVAD() },
                makeRecognizer: { ScriptedRecognizer(lines: []) }, answerer: MockAnswerer()))
        let title = "email Anna \(UUID().uuidString.prefix(6))"
        let h = try await p.ask(question: "Remind me to \(title) tomorrow at nine")
        await p.respondToApproval("yes")
        var spoken: [String] = []
        for await e in h.events { if case .sentence(let s) = e { spoken.append(s) } }
        XCTAssertEqual(spoken.last, "Reminder created.")
        let found: [(id: String, title: String, hour: Int?)] = await withCheckedContinuation { c in
            ek.fetchReminders(matching: ek.predicateForReminders(in: nil)) { rs in
                c.resume(
                    returning: (rs ?? []).map {
                        ($0.calendarItemIdentifier, $0.title ?? "", $0.dueDateComponents?.hour)
                    })
            }
        }
        let r = try XCTUnwrap(found.first { $0.title.lowercased() == title.lowercased() })
        XCTAssertEqual(r.hour, 9)
        if let item = ek.calendarItem(withIdentifier: r.id) as? EKReminder { try ek.remove(item, commit: true) }
    }
}
