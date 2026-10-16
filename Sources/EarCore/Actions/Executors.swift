import EventKit
import Foundation
import GRDB

public protocol ActionExecutor: Sendable {
    func execute(_ a: EarAction) async throws -> String  // spoken confirmation
}

/// EventKit behind a protocol so tests do not touch the user's calendars (P6.3).
public protocol EventStoring: Sendable {
    func requestAccess(toReminders: Bool) async throws -> Bool
    func addReminder(title: String, due: Date?) throws
    func addEvent(title: String, start: Date, end: Date) throws
}

public final class EventKitStore: EventStoring, @unchecked Sendable {
    private let store = EKEventStore()
    public init() {}

    public func requestAccess(toReminders: Bool) async throws -> Bool {
        toReminders ? try await store.requestFullAccessToReminders() : try await store.requestWriteOnlyAccessToEvents()
    }

    public func addReminder(title: String, due: Date?) throws {
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = store.defaultCalendarForNewReminders()
        if let due {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(r, commit: true)
    }

    public func addEvent(title: String, start: Date, end: Date) throws {
        let e = EKEvent(eventStore: store)
        (e.title, e.startDate, e.endDate) = (title, start, end)
        e.calendar = store.defaultCalendarForNewEvents
        try store.save(e, span: .thisEvent, commit: true)
    }
}

/// Runs approved actions (P6.3). Failures are thrown as spoken text.
public struct EarActionExecutor: ActionExecutor {
    let store: SQLiteTranscriptStore
    let events: any EventStoring
    let search: (any WebSearching)?
    let answerer: (any Answerer)?

    public init(
        store: SQLiteTranscriptStore, events: any EventStoring = EventKitStore(), search: (any WebSearching)? = nil,
        answerer: (any Answerer)? = nil
    ) {
        (self.store, self.events, self.search, self.answerer) = (store, events, search, answerer)
    }

    public func execute(_ a: EarAction) async throws -> String {
        switch a {
        case .note(let text):
            try await store.addNote(text)
            return "Saved the note."
        case .reminder(let text, let at):
            guard try await events.requestAccess(toReminders: true) else {
                throw EarError.model("I'm not allowed to add reminders.")
            }
            try events.addReminder(title: text, due: at)
            return "Reminder created."
        case .calendar(let title, let start, let end):
            guard try await events.requestAccess(toReminders: false) else {
                throw EarError.model("I'm not allowed to add events.")
            }
            try events.addEvent(title: title, start: start, end: end)
            return "Added to your calendar."
        case .pinWindow(let seconds):
            let n = try await store.pinLast(seconds: seconds)
            return "Pinned \(n) segment\(n == 1 ? "" : "s")."
        case .webSearch(let query):
            guard let search else { return "Web search is off. Turn it on in Settings, under Web search." }
            let results = try await search.search(query)
            guard let top = results.first else { return "I found nothing on the web for \(query)." }
            return "According to \(top.domain), \(try await summary(query, results))"
        }
    }

    /// The answerer sums up the results (ADR-021); without one, the top snippet is read out.
    private func summary(_ query: String, _ results: [WebResult]) async throws -> String {
        var text = results[0].snippet
        if let answerer {
            let notes = results.map { "Web result from \($0.domain): \($0.title). \($0.snippet)" }
            var out = ""
            for try await e in answerer.answer(
                AnswerRequest(question: query, intent: .freeform, window: [], retrieved: [], notes: notes))
            {
                if case .token(let t) = e { out += t }
            }
            let parsed = PromptBuilder.parseSource(out).answer
            if !parsed.isEmpty { text = parsed }
        }
        return text.prefix(1).lowercased() + text.dropFirst()
    }
}

public struct Note: Sendable, Codable, Equatable {
    public let id: Int64, createdAt: Date, text: String, sessionID: String?
}

extension SQLiteTranscriptStore {
    public func addNote(_ text: String) async throws {
        let session = currentSession
        try await db.write {
            try $0.execute(
                sql: "INSERT INTO notes (created_at, text, session_id) VALUES (?,?,?)",
                arguments: [Date().timeIntervalSince1970, text, session])
        }
    }

    public func notes() async throws -> [Note] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM notes ORDER BY id DESC").map {
                Note(
                    id: $0["id"], createdAt: Date(timeIntervalSince1970: $0["created_at"]), text: $0["text"],
                    sessionID: $0["session_id"])
            }
        }
    }

    /// Pins every segment of the current session that ended in the last `seconds` (pipeline clock).
    public func pinLast(seconds: TimeInterval) async throws -> Int {
        let segs = try await window(seconds: seconds, before: nil)
        for s in segs { try await pin(s.id!, true) }
        return segs.count
    }
}
