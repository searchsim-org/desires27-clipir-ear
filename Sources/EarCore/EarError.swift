import Foundation

public enum EarError: Error, Sendable, Equatable {
    case audio(String)
    case egressBlocked(host: String)
    case notFound(String)
    case model(String)
    case cancelled
}
