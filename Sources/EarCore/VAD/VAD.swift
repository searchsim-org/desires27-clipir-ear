import Foundation
import SherpaOnnxC
import Synchronization

public enum VADEvent: Sendable, Equatable {
    case speechStart(TimeInterval)
    case speechEnd(TimeInterval)
}

public protocol VoiceActivityDetector: Sendable {
    func process(_ frame: PCMFrame) -> VADEvent?
    func reset()
}

/// Dependency-free energy VAD for unit tests and as a fallback (P2.1).
public final class EnergyVAD: VoiceActivityDetector {
    private let threshold: Float
    private let hangoverFrames: Int
    private let state = Mutex((speaking: false, quiet: 0))

    public init(threshold: Float = 0.01, hangoverMs: Int = 300) {
        self.threshold = threshold
        self.hangoverFrames = hangoverMs / 20
    }

    public func process(_ frame: PCMFrame) -> VADEvent? {
        let loud = frame.rms > threshold
        return state.withLock { s in
            if loud {
                s.quiet = 0
                if !s.speaking {
                    s.speaking = true
                    return .speechStart(frame.timestamp)
                }
            } else if s.speaking {
                s.quiet += 1
                if s.quiet >= hangoverFrames {
                    s.speaking = false
                    return .speechEnd(frame.timestamp + 0.02 - Double(hangoverFrames) * 0.02)
                }
            }
            return nil
        }
    }

    public func reset() { state.withLock { $0 = (false, 0) } }
}

/// Silero VAD v5 through sherpa-onnx, 512-sample windows at 16 kHz, configurable hangover (P2.1).
public final class SileroVAD: VoiceActivityDetector, @unchecked Sendable {
    private let vad: OpaquePointer
    private let state = Mutex((speaking: false, samples: 0))

    public init(modelPath: String? = nil, threshold: Float = 0.5, hangoverMs: Int = 300) throws {
        let model = try modelPath ?? Models.path(Models.sileroVAD)
        var config = SherpaOnnxVadModelConfig()
        let created: OpaquePointer? = model.withCString { m in
            "cpu".withCString { cpu in
                config.silero_vad.model = m
                config.silero_vad.threshold = threshold
                config.silero_vad.min_silence_duration = Float(hangoverMs) / 1000
                config.silero_vad.min_speech_duration = 0.25
                config.silero_vad.window_size = 512
                config.silero_vad.max_speech_duration = 20
                config.sample_rate = 16_000
                config.num_threads = 1
                config.provider = cpu
                return SherpaOnnxCreateVoiceActivityDetector(&config, 60)
            }
        }
        guard let created else { throw EarError.model("could not load Silero VAD at \(model)") }
        vad = created
    }

    deinit { SherpaOnnxDestroyVoiceActivityDetector(vad) }

    public func process(_ frame: PCMFrame) -> VADEvent? {
        let floats = frame.samples.map { Float($0) / 32768 }
        return state.withLock { s in
            floats.withUnsafeBufferPointer {
                SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, $0.baseAddress, Int32($0.count))
            }
            s.samples += floats.count
            // we only need events
            while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 { SherpaOnnxVoiceActivityDetectorPop(vad) }
            let detected = SherpaOnnxVoiceActivityDetectorDetected(vad) != 0
            defer { s.speaking = detected }
            switch (s.speaking, detected) {
            case (false, true): return .speechStart(frame.timestamp)
            case (true, false): return .speechEnd(frame.timestamp + 0.02)
            default: return nil
            }
        }
    }

    public func reset() {
        state.withLock { s in
            SherpaOnnxVoiceActivityDetectorReset(vad)
            s = (false, 0)
        }
    }
}
