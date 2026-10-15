import Foundation

public enum Intent: String, Codable, Sendable, CaseIterable {
    case explainLast, expand, summarizeWindow, whoSaid, translate, noteThis, remindMe, searchWeb, freeform
}

/// Rule-first intent detection (§8.1) from Assets/intents.en.json. The model-based fallback for
/// unmatched long questions is Mac-tier only (Phase 5); on the phone they stay `freeform`.
public struct IntentDetector: Sendable {
    struct Table: Decodable {
        struct Rule: Decodable {
            let intent: Intent
            let patterns: [String]
        }
        let rules: [Rule]
        let numbers: [String: Int]
    }

    private let rules: [(Intent, [NSRegularExpression])]
    private let numbers: [String: Int]

    public init(locale: Locale = Locale(identifier: "en-US")) {
        let lang = locale.language.languageCode?.identifier ?? "en"
        let url =
            Bundle.module.url(forResource: "intents.\(lang)", withExtension: "json", subdirectory: "Assets")
            ?? Bundle.module.url(forResource: "intents.en", withExtension: "json", subdirectory: "Assets")!
        // ponytail: a malformed bundled table is a programming error caught by IntentDetectorTests.
        let table = try! JSONDecoder().decode(Table.self, from: Data(contentsOf: url))
        rules = table.rules.map { r in
            (r.intent, r.patterns.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) })
        }
        numbers = table.numbers
    }

    public func detect(_ question: String) -> Intent {
        let range = NSRange(question.startIndex..., in: question)
        for (intent, patterns) in rules
        where patterns.contains(where: { $0.firstMatch(in: question, range: range) != nil }) {
            return intent
        }
        return .freeform
    }

    /// "the last N minutes" → N (digits or words); nil when absent.
    public func minutes(in question: String) -> Int? {
        let q = question.lowercased()
        guard let m = q.range(of: #"(\d+|[a-z]+) minutes?"#, options: .regularExpression) else { return nil }
        let word = String(q[m].split(separator: " ")[0])
        return Int(word) ?? numbers[word]
    }
}
