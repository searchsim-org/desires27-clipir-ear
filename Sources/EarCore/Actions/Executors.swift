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

    public init(store: SQLiteTranscriptStore, events: any EventStoring = EventKitStore()) {
        (self.store, self.events) = (store, events)
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
        case .webSearch:
            return "Web search is disabled in this build."  // v0.1: recorded, never sent (§P6.1)
        }
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
