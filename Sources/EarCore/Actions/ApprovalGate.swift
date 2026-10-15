import Foundation

public enum ApprovalOutcome: Sendable, Equatable {
    case accepted(EarAction)
    case edited(EarAction)
    case dismissed, timeout

    /// voice_queries.action_response
    public var response: String {
        switch self {
        case .accepted: "accepted"
        case .edited: "edited"
        case .dismissed: "dismissed"
        case .timeout: "timeout"
        }
    }
}

/// Spoken approval (P6.2): say the proposal, listen 4 s for yes / no / cancel / "change …"; after a yes, a 2 s
/// window in which "cancel" (or a stem press, delivered as "cancel") still stops it.
public struct ApprovalGate: Sendable {
    public var listenSeconds: TimeInterval = 4
    public var cancelWindow: TimeInterval = 2
    let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    public func run(
        _ action: EarAction, speak: @Sendable (String) async -> Void, listen: @Sendable (TimeInterval) async -> String?
    ) async -> ApprovalOutcome {
        await speak(action.proposal)
        guard let reply = await listen(listenSeconds), !reply.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .timeout
        }
        let r = reply.lowercased()
        if r.range(of: #"\b(no|nope|cancel|stop|don'?t)\b"#, options: .regularExpression) != nil { return .dismissed }
        if r.range(of: #"\b(change|make it|move it)\b"#, options: .regularExpression) != nil {
            return edit(action, with: reply).map { .edited($0) } ?? .dismissed
        }
        if r.range(of: #"\b(yes|yeah|yep|sure|confirm|okay|ok|do it)\b"#, options: .regularExpression) != nil {
            let late = await listen(cancelWindow)?.lowercased() ?? ""
            return late.range(of: #"\b(cancel|stop|no)\b"#, options: .regularExpression) != nil
                ? .dismissed : .accepted(action)
        }
        return .dismissed
    }

    /// "change it to Friday at 3" → same action with the new time; "change it to call Anna" → new text.
    func edit(_ a: EarAction, with reply: String) -> EarAction? {
        let body = ActionDetector.clean(reply, dropping: #"^(no,? )?(change|make|move) it( to)?"#)
        switch a {
        case .reminder(let text, let at):
            if let (date, rest) = ActionDetector.date(in: body, now: now()) {
                let newText = ActionDetector.clean(rest)
                return .reminder(text: newText.isEmpty ? text : newText, at: Self.merge(date, into: at))
            }
            return body.isEmpty ? nil : .reminder(text: body, at: at)
        case .calendar(let title, let start, let end):
            guard let (date, _) = ActionDetector.date(in: body, now: now()) else { return nil }
            let s = Self.merge(date, into: start)
            return .calendar(title: title, start: s, end: s.addingTimeInterval(end.timeIntervalSince(start)))
        case .note: return body.isEmpty ? nil : .note(text: body)
        default: return nil
        }
    }

    /// A bare day ("Friday") keeps the original time of day.
    static func merge(_ new: Date, into old: Date?) -> Date {
        guard let old else { return new }
        let cal = Calendar.current
        let t = cal.dateComponents([.hour, .minute], from: new)
        if t.hour == 12, t.minute == 0 {  // NSDataDetector's default for a date without a time
            let o = cal.dateComponents([.hour, .minute], from: old)
            return cal.date(bySettingHour: o.hour ?? 9, minute: o.minute ?? 0, second: 0, of: new) ?? new
        }
        return new
    }
}
