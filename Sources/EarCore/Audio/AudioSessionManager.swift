#if os(iOS)
    @preconcurrency import AVFoundation
    import Foundation

    public enum PreferredInput: Sendable { case automatic, builtIn, bluetoothHFP }

    public struct AudioRouteState: Sendable, Equatable {
        public var inputs: [String]  // "BluetoothHFP: AirPods Pro", "MicrophoneBuiltIn: iPhone Microphone"
        public var outputs: [String]
        public var inputName: String { inputs.first ?? "none" }
        public init(inputs: [String] = [], outputs: [String] = []) {
            self.inputs = inputs
            self.outputs = outputs
        }
    }

    public enum SessionHealth: Sendable, Equatable {
        case ok
        case interrupted(reason: String)
        case ended(reason: String)
    }

    /// AVAudioSession configuration and observation (P1.1). iOS 18 SDK names (ADR-008): `.allowBluetooth` is HFP.
    @MainActor
    public final class AudioSessionManager {
        private let session = AVAudioSession.sharedInstance()
        private var tokens: [NSObjectProtocol] = []
        public let health: AsyncStream<SessionHealth>
        private let healthContinuation: AsyncStream<SessionHealth>.Continuation
        public let routes: AsyncStream<AudioRouteState>
        private let routesContinuation: AsyncStream<AudioRouteState>.Continuation

        public init() {
            (health, healthContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
            (routes, routesContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        }

        /// `capture: false` (fixture sources) uses a playback-only session: no microphone path is opened, which
        /// also keeps the simulator from blocking on the Mac's microphone permission (MAC-1).
        /// `remoteControls: true` (AirPods stem press) leaves out `.duckOthers`: it implies `.mixWithOthers`, and a
        /// mixable session never becomes the Now Playing app, so play/pause from the AirPods would not reach us.
        public func activate(
            preferredInput: PreferredInput = .automatic, capture: Bool = true, remoteControls: Bool = false
        ) throws {
            if capture {
                var options: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
                if !remoteControls { options.insert(.duckOthers) }
                try session.setCategory(.playAndRecord, mode: .default, options: options)
                try session.setPreferredSampleRate(16_000)
            } else {
                try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            }
            try session.setActive(true)
            if capture { try setPreferredInput(preferredInput) }
            observe()
            routesContinuation.yield(currentRoute())
            healthContinuation.yield(.ok)
        }

        public func deactivate() {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }

        public func setPreferredInput(_ p: PreferredInput) throws {
            let ports = session.availableInputs ?? []
            let want: AVAudioSession.Port? =
                switch p {
                case .automatic: nil
                case .builtIn: .builtInMic
                case .bluetoothHFP: .bluetoothHFP
                }
            try session.setPreferredInput(want.flatMap { w in ports.first { $0.portType == w } })
        }

        public func currentRoute() -> AudioRouteState {
            let r = session.currentRoute
            return AudioRouteState(
                inputs: r.inputs.map { "\($0.portType.rawValue): \($0.portName)" },
                outputs: r.outputs.map { "\($0.portType.rawValue): \($0.portName)" })
        }

        /// iOS forbids starting recording in the background (§17): on interruption end we try once, and if
        /// that fails we report `.ended` so the UI shows "Listening stopped — tap to resume". Never spin-retry.
        private func observe() {
            let nc = NotificationCenter.default
            tokens.append(
                nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) {
                    note in
                    let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(
                        AVAudioSession.InterruptionType.init)
                    MainActor.assumeIsolated {
                        switch type {
                        case .began:
                            self.healthContinuation.yield(.interrupted(reason: "interrupted by another app or a call"))
                        case .ended:
                            do {
                                try self.session.setActive(true)
                                self.healthContinuation.yield(.ok)
                            } catch {
                                self.healthContinuation.yield(
                                    .ended(reason: "could not resume: \(error.localizedDescription)"))
                            }
                        default: break
                        }
                    }
                })
            tokens.append(
                nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { _ in
                    MainActor.assumeIsolated { self.routesContinuation.yield(self.currentRoute()) }
                })
            tokens.append(
                nc.addObserver(
                    forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
                ) { _ in
                    MainActor.assumeIsolated {
                        self.healthContinuation.yield(.ended(reason: "audio services were reset"))
                    }
                })
        }
    }
#endif
