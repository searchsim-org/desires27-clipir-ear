import Foundation

/// Push-to-talk state machine (P3.1): idle → capturingQuestion (PTT down) → finalizing (PTT up) → routing →
/// answering → speaking → idle. `cancel` returns to idle from any state.
public struct QueryRouter: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case idle, capturingQuestion, finalizing, routing, answering, speaking
    }
    public enum Event: Sendable { case pttDown, pttUp, asrFinal, contextReady, firstSentence, done, cancel }

    public private(set) var state: State = .idle
    public init() {}

    /// Applies an event; returns false (and keeps the state) for an illegal transition.
    @discardableResult
    public mutating func handle(_ e: Event) -> Bool {
        let next: State? =
            switch (state, e) {
            case (_, .cancel): .idle
            case (.idle, .pttDown), (.speaking, .pttDown), (.answering, .pttDown): .capturingQuestion  // barge-in
            case (.capturingQuestion, .pttUp): .finalizing
            case (.finalizing, .asrFinal): .routing
            case (.routing, .contextReady): .answering
            case (.answering, .firstSentence): .speaking
            case (.answering, .done), (.speaking, .done): .idle
            default: nil
            }
        guard let next else { return false }
        state = next
        return true
    }
}
