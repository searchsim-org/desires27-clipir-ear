import Foundation

/// Proactive cues (P8.6, off by default): a final segment that mentions a word from the user's notes or pinned
/// segments earns a short whispered cue. At most `maxPerHour` cues, and one per keyword per hour.
public struct CueEngine: Sendable {
    public var maxPerHour = 6
    private var fired: [(at: TimeInterval, keyword: String)] = []
    public init() {}

    // ponytail: length + stop-list keywords; switch to embeddings when cues prove too noisy in a device check
    static let stop: Set<String> = [
        "about", "after", "again", "because", "before", "being", "could", "every", "first", "going", "great",
        "their", "there", "these", "thing", "things", "think", "those", "today", "where", "which", "while",
        "would", "should", "remember", "really", "something",
    ]

    public static func keywords(from texts: [String]) -> Set<String> {
        Set(texts.flatMap(words).filter { $0.count >= 5 && !stop.contains($0) })
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// The cue to speak for `text` at time `now` (seconds, any monotonic clock), or nil.
    public mutating func cue(for text: String, keywords: Set<String>, at now: TimeInterval) -> String? {
        fired.removeAll { now - $0.at >= 3600 }
        guard fired.count < maxPerHour,
            let hit = Self.words(text).first(where: { w in keywords.contains(w) && !fired.contains { $0.keyword == w } }
            )
        else { return nil }
        fired.append((now, hit))
        return "Heads up: \(hit)."
    }
}
