import Foundation

/// Spoken requests that become typed actions (P6.1). Calendar and pin phrases are detected here even though the
/// §8.1 intent table has no intent for them (ADR-018); everything goes through the ApprovalGate before it runs.
public struct ActionDetector: Sendable {
    let now: @Sendable () -> Date
    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    static let hourWords = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "noon": 12,
    ]

    public func detect(_ question: String, intent: Intent, window: [Segment]) -> EarAction? {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = q.lowercased()
        if let r = lower.range(of: #"\bpin (this|that|the last (\w+) minutes?)"#, options: .regularExpression) {
            let words = lower[r].split(separator: " ")
            let n = words.count >= 4 ? Int(words[3]) ?? Self.hourWords[String(words[3])] ?? 1 : 1
            return .pinWindow(seconds: Double(n) * 60)
        }
        if lower.range(of: #"\b(calendar|schedule|book a meeting)\b"#, options: .regularExpression) != nil,
            let (date, rest) = Self.date(in: q, now: now())
        {
            let title = Self.clean(
                rest, dropping: #"^(please )?(put|add|schedule|book)( a| an)?( meeting| event)?"#,
                #"(in|to|on) my calendar"#)
            return .calendar(title: title.isEmpty ? "Meeting" : title, start: date, end: date.addingTimeInterval(3600))
        }
        switch intent {
        case .noteThis:
            if let quoted = q.range(of: #"["“](.+?)["”]"#, options: .regularExpression) {
                return .note(text: String(q[quoted]).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”")))
            }
            if let colon = q.firstIndex(of: ":"), q[colon...].count > 3 {
                return .note(text: q[q.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
            let end = window.last?.t1 ?? 0
            return .note(text: window.filter { $0.t1 > end - 30 }.map(\.text).joined(separator: " "))
        case .remindMe:
            let (date, rest) = Self.date(in: q, now: now()) ?? (nil, q)
            return .reminder(text: Self.clean(rest, dropping: #"^(please )?remind me( to| about| that)?"#), at: date)
        case .searchWeb:
            return .webSearch(
                query: Self.clean(q, dropping: #"^(please )?(search the web|look (it|that) up online)( for)?"#))
        default:
            return nil
        }
    }

    /// "stop listening" / "pause listening" said as the whole request (not inside a question about it).
    public static func isStopListening(_ question: String) -> Bool {
        question.range(
            of: #"^\W*(please |ok |okay )?(stop|pause) listening\b"#, options: [.regularExpression, .caseInsensitive])
            != nil
    }

    /// "forget the last ten minutes" → 10 (spoken purge, §10.3); nil otherwise.
    public static func forgetMinutes(_ question: String) -> Int? {
        let q = question.lowercased()
        guard
            let r = q.range(
                of: #"\b(forget|delete|erase) (the last|what was said in the last) (\w+) minutes?"#,
                options: .regularExpression)
        else { return nil }
        let word = String(q[r].split(separator: " ").dropLast().last ?? "")
        return Int(word) ?? hourWords[word] ?? ["fifteen": 15, "twenty": 20, "thirty": 30][word]
    }

    /// First date phrase (after turning "at nine" into "at 9:00") and the text without it.
    static func date(in text: String, now: Date) -> (Date, String)? {
        var t = text
        for (w, h) in hourWords {
            t = t.replacingOccurrences(
                of: #"\b(at|by) \#(w)\b"#, with: "$1 \(h):00", options: [.regularExpression, .caseInsensitive])
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
            let m = detector.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), var date = m.date,
            let r = Range(m.range, in: t)
        else { return nil }
        if date < now, t.lowercased().contains("tomorrow") == false, date.addingTimeInterval(86_400) > now {
            date = date.addingTimeInterval(86_400)  // "at 9" said at 10 means tomorrow
        }
        return (date, t.replacingCharacters(in: r, with: ""))
    }

    static func clean(_ s: String, dropping patterns: String...) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in patterns {
            t = t.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        t = t.replacingOccurrences(of: #"\s+(at|on|by|for)?\s*$"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " .,?!")).replacingOccurrences(of: "  ", with: " ")
    }
}

extension EarAction {
    /// What the ApprovalGate says, and what goes into voice_queries.action_proposed.
    public var proposal: String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        switch self {
        case .note(let text): return "Save a note: \"\(text.prefix(80))\"? Say yes to confirm."
        case .reminder(let text, let at):
            return
                "Create a reminder to \(text)\(at.map { " " + f.string(from: $0).lowercased() } ?? "")? Say yes to confirm."
        case .calendar(let title, let start, _):
            return "Add \(title) to your calendar, \(f.string(from: start).lowercased())? Say yes to confirm."
        case .pinWindow(let seconds):
            return "Pin the last \(Int(seconds / 60)) minutes of the transcript? Say yes to confirm."
        case .webSearch(let query): return "Search the web for \(query)? Say yes to confirm."
        }
    }

    public var json: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }
}
