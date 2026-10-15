import ActivityKit
import Foundation

/// P8.2 / PRIVACY §10.7: the "Listening" Live Activity, shared by the app (starts/ends it) and the widget (draws it).
struct ListeningActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var recording: Bool
        var retentionMinutes: Int
    }
    var startedAt: Date
}
