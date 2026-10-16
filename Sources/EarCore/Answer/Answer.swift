import Foundation
import Synchronization

public struct AnswerRequest: Sendable {
    public var question: String
    public var intent: Intent
    public var window: [Segment]  // last N seconds
    public var retrieved: [Segment]  // top-k beyond the window
    public var notes: [String]  // pinned notes / ClipIR snippets (may be empty)
    public var locale: Locale
    public var maxTokens: Int
    public var windowSeconds: TimeInterval = 60
    public var minutes: Int? = nil
    public var tier: Tier = .phone

    public init(
        question: String, intent: Intent, window: [Segment], retrieved: [Segment], notes: [String],
        locale: Locale = Locale(identifier: "en-US"), maxTokens: Int = 160
    ) {
        (self.question, self.intent, self.window, self.retrieved, self.notes) = (
            question, intent, window, retrieved, notes
        )
        (self.locale, self.maxTokens) = (locale, maxTokens)
    }
}

public enum AnswerEvent: Sendable {
    case token(String)
    case sentence(String)  // emitted when a sentence boundary is detected
    case tier(String)  // "phone" | "mac"
    case knowledgeTier(String)  // "transcript" | "notes" | "general" | "none"
    case proposedAction(EarAction)
    case done(promptTokens: Int, completionTokens: Int)
}

public enum EarAction: Codable, Sendable, Equatable {
    case note(text: String)
    case reminder(text: String, at: Date?)
    case calendar(title: String, start: Date, end: Date)
    case pinWindow(seconds: TimeInterval)
    case webSearch(query: String)  // always approval-gated; leaves device
}

public protocol Answerer: AnyObject, Sendable {
    var name: String { get }
    func answer(_ req: AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error>
    func cancel()
}

/// System + user prompts from Assets/Prompts (§8.3); `SOURCE:` parsing.
public enum PromptBuilder {
    static func template(_ name: String) -> String {
        let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Assets/Prompts")!
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    public static func system(_ req: AnswerRequest) -> String {
        template("system")
            .replacingOccurrences(
                of: "{locale_language}",
                with: req.locale.localizedString(forLanguageCode: req.locale.language.languageCode?.identifier ?? "en")
                    ?? "English"
            )
            .replacingOccurrences(of: "{max_words}", with: req.tier == .phone ? "80" : "140")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func user(_ req: AnswerRequest) -> String {
        let name: String =
            switch req.intent {
            case .explainLast, .expand, .summarizeWindow, .whoSaid: req.intent.rawValue
            default: "freeform"
            }
        let lines = { (segs: [Segment]) in
            segs.isEmpty ? "(nothing)" : segs.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")
        }
        return template(name)
            .replacingOccurrences(of: "{W}", with: String(Int(req.windowSeconds)))
            .replacingOccurrences(of: "{N}", with: String(req.minutes ?? Int(req.windowSeconds / 60)))
            .replacingOccurrences(of: "{window}", with: lines(req.window))
            .replacingOccurrences(of: "{retrieved}", with: lines(req.retrieved))
            .replacingOccurrences(of: "{notes}", with: req.notes.isEmpty ? "(none)" : req.notes.joined(separator: "\n"))
            .replacingOccurrences(of: "{question}", with: req.question)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The part of a still-streaming answer to show on screen: everything before the `SOURCE:` line, and without a
    /// last line that may be that line arriving token by token ("SOU").
    public static func visibleWhileStreaming(_ text: String) -> String {
        var s = text
        if let r = s.range(of: #"SOURCE\s*:"#, options: [.regularExpression, .caseInsensitive]) {
            s = String(s[..<r.lowerBound])
        } else if let nl = s.lastIndex(of: "\n") {
            let tail = s[s.index(after: nl)...].trimmingCharacters(in: .whitespaces).uppercased()
            if "SOURCE:".hasPrefix(tail) { s = String(s[..<nl]) }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits a finished answer into the spoken text and the knowledge tier from its `SOURCE:` line.
    public static func parseSource(_ text: String) -> (answer: String, tier: String) {
        guard let r = text.range(of: #"SOURCE:\s*([a-z]+)"#, options: [.regularExpression, .caseInsensitive]) else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), "none")
        }
        let tier = text[r].split(separator: ":").last!.trimmingCharacters(in: .whitespaces).lowercased()
        let valid = ["transcript", "notes", "general", "none"].contains(tier) ? tier : "none"
        return (String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines), valid)
    }
}

/// Streams sentences out of a token stream (§P3.5/P4.1): boundary at . ? ! : followed by space/newline,
/// at least 6 words, not after a known abbreviation. `SOURCE:` lines are never emitted as speech.
public struct SentenceSplitter: Sendable {
    static let abbreviations: Set<String> = [
        "e.g.", "i.e.", "dr.", "mr.", "mrs.", "ms.", "prof.", "etc.", "vs.", "no.", "st.",
    ]
    private var buffer = ""
    private var emitted = 0
    public let minWords: Int
    /// The first chunk may end at `,` `;` or `—` once it has 4 words, so a TTS that cannot start mid-sentence
    /// (Kokoro, ADR-020) begins speaking sooner. Later chunks follow the normal rule.
    public let firstClause: Bool

    public init(minWords: Int = 6, firstClause: Bool = false) {
        self.minWords = minWords
        self.firstClause = firstClause
    }

    public mutating func push(_ token: String) -> [String] {
        buffer += token
        var out: [String] = []
        while let s = nextSentence() {
            out.append(s)
            emitted += 1  // per chunk: the first-clause rule applies to the very first one only
        }
        return out
    }

    public mutating func flush() -> String? {
        defer { buffer = "" }
        let s = Self.clean(buffer)
        return s.isEmpty ? nil : s
    }

    private mutating func nextSentence() -> String? {
        var idx = buffer.startIndex
        while idx < buffer.endIndex {
            let c = buffer[idx]
            let next = buffer.index(after: idx)
            if firstClause, emitted == 0, ",;—".contains(c), next < buffer.endIndex, buffer[next] == " ",
                buffer[...idx].split(separator: " ").count >= 4
            {
                let candidate = String(buffer[...idx])
                buffer = String(buffer[next...])
                let s = Self.clean(candidate)
                if !s.isEmpty { return s }
            } else if ".?!:".contains(c), next < buffer.endIndex, buffer[next] == " " || buffer[next] == "\n" {
                let candidate = String(buffer[...idx])
                let lastWord = candidate.split(separator: " ").last.map { $0.lowercased() } ?? ""
                let words = candidate.split { $0 == " " || $0 == "\n" }.count
                if !Self.abbreviations.contains(lastWord), words >= minWords || c == "\n" {
                    buffer = String(buffer[next...])
                    let s = Self.clean(candidate)
                    if !s.isEmpty { return s }
                }
            } else if c == "\n", buffer[..<idx].split(separator: " ").count >= minWords {
                let candidate = String(buffer[..<idx])
                buffer = String(buffer[next...])
                let s = Self.clean(candidate)
                if !s.isEmpty { return s }
            }
            idx = next
        }
        return nil
    }

    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "SOURCE:", options: .caseInsensitive) {
            t = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }
}

/// Scripted answers for tests and UI work (P3.6).
public final class MockAnswerer: Answerer {
    public let name = "mock"
    private let reply: @Sendable (AnswerRequest) -> String
    private let cancelled = Mutex(false)

    public init(
        reply: @escaping @Sendable (AnswerRequest) -> String = { _ in
            "This is a scripted answer for testing purposes.\nSOURCE: none"
        }
    ) {
        self.reply = reply
    }

    public func answer(_ req: AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error> {
        cancelled.withLock { $0 = false }
        let text = reply(req)
        return AsyncThrowingStream { c in
            c.yield(.tier(req.tier.rawValue))
            var splitter = SentenceSplitter(firstClause: true)  // ADR-020: speak the first clause early
            var n = 0
            for word in text.split(separator: " ", omittingEmptySubsequences: false) {
                if cancelled.withLock({ $0 }) { break }
                let tok = (n == 0 ? "" : " ") + word
                n += 1
                c.yield(.token(tok))
                for s in splitter.push(tok) { c.yield(.sentence(s)) }
            }
            if let s = splitter.flush() { c.yield(.sentence(s)) }
            c.yield(.knowledgeTier(PromptBuilder.parseSource(text).tier))
            c.yield(.done(promptTokens: 0, completionTokens: n))
            c.finish()
        }
    }

    public func cancel() { cancelled.withLock { $0 = true } }
}
