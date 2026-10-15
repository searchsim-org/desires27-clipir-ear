import Foundation
import SherpaOnnxC
import Synchronization

public struct ASRResult: Sendable, Equatable {
    public var text: String
    public var isFinal: Bool
    public var t0: TimeInterval, t1: TimeInterval  // pipeline clock
    public var confidence: Double?
    public var engine: String
    public init(
        text: String, isFinal: Bool, t0: TimeInterval, t1: TimeInterval, confidence: Double? = nil, engine: String
    ) {
        (self.text, self.isFinal, self.t0, self.t1, self.confidence, self.engine) = (
            text, isFinal, t0, t1, confidence, engine
        )
    }
}

public protocol StreamingRecognizer: AnyObject, Sendable {
    var results: AsyncStream<ASRResult> { get }
    func start(locale: Locale) async throws
    func feed(_ frame: PCMFrame)
    func finishUtterance() async  // force finalisation of pending audio
    func stop() async
}

/// Streaming Zipformer (English) via sherpa-onnx (P2.3, ADR-008: the only on-phone engine).
/// Endpointing: 0.8 s trailing silence or 20 s utterance. Partial text goes to the UI; finals to the store.
public final class SherpaStreamingRecognizer: StreamingRecognizer, @unchecked Sendable {
    public static let engineName = "sherpa:zipformer-en-2023-06-26"
    public let results: AsyncStream<ASRResult>
    private let continuation: AsyncStream<ASRResult>.Continuation
    private let recognizer: OpaquePointer
    private let state: Mutex<State>

    struct State {
        var stream: OpaquePointer?
        var lastText = ""
        var t0: TimeInterval?
        var tLast: TimeInterval = 0
    }

    public init(numThreads: Int = 2) throws {
        let paths = try [
            Models.Zipformer.encoder, Models.Zipformer.decoder, Models.Zipformer.joiner, Models.Zipformer.tokens,
        ].map(Models.path)
        var config = SherpaOnnxOnlineRecognizerConfig()
        let created: OpaquePointer? = paths[0].withCString { enc in
            paths[1].withCString { dec in
                paths[2].withCString { join in
                    paths[3].withCString { tok in
                        "cpu".withCString { cpu in
                            "greedy_search".withCString { greedy in
                                config.feat_config.sample_rate = 16_000
                                config.feat_config.feature_dim = 80
                                config.model_config.transducer.encoder = enc
                                config.model_config.transducer.decoder = dec
                                config.model_config.transducer.joiner = join
                                config.model_config.tokens = tok
                                config.model_config.num_threads = Int32(numThreads)
                                config.model_config.provider = cpu
                                config.decoding_method = greedy
                                config.enable_endpoint = 1
                                config.rule1_min_trailing_silence = 2.4
                                config.rule2_min_trailing_silence = 0.8
                                config.rule3_min_utterance_length = 20
                                return SherpaOnnxCreateOnlineRecognizer(&config)
                            }
                        }
                    }
                }
            }
        }
        guard let created else { throw EarError.model("could not load the streaming Zipformer") }
        recognizer = created
        state = Mutex(State(stream: SherpaOnnxCreateOnlineStream(created)))
        (results, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        state.withLock { if let s = $0.stream { SherpaOnnxDestroyOnlineStream(s) } }
        SherpaOnnxDestroyOnlineRecognizer(recognizer)
    }

    public func start(locale: Locale) async throws {
        guard locale.language.languageCode?.identifier ?? "en" == "en" else {
            throw EarError.model("the streaming Zipformer is English only (ADR-004)")
        }
    }

    public func feed(_ frame: PCMFrame) {
        let floats = frame.samples.map { Float($0) / 32768 }
        let out = state.withLock { s -> [ASRResult] in
            guard let stream = s.stream else { return [] }
            floats.withUnsafeBufferPointer {
                SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, $0.baseAddress, Int32($0.count))
            }
            s.tLast = frame.timestamp + 0.02
            var emitted: [ASRResult] = []
            while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 {
                SherpaOnnxDecodeOnlineStream(recognizer, stream)
            }
            let text = Self.text(recognizer, stream)
            if text != s.lastText, !text.isEmpty {
                // first words of this utterance: start time ≈ now minus the model's ~0.3 s decoding latency
                if s.t0 == nil { s.t0 = max(0, frame.timestamp - 0.3) }
                s.lastText = text
                emitted.append(
                    ASRResult(text: Self.tidy(text), isFinal: false, t0: s.t0!, t1: s.tLast, engine: Self.engineName))
            }
            if SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream) != 0 {
                if let f = Self.finalize(&s) { emitted.append(f) }
                SherpaOnnxOnlineStreamReset(recognizer, stream)
            }
            return emitted
        }
        for r in out { continuation.yield(r) }
    }

    public func finishUtterance() async {
        let out = state.withLock { s -> ASRResult? in
            guard let stream = s.stream else { return nil }
            // Pad 0.8 s of silence so the last word leaves the model's lookahead (0.5 s cut "twelve" to "twel").
            let pad = [Float](repeating: 0, count: 12_800)
            pad.withUnsafeBufferPointer {
                SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, $0.baseAddress, Int32($0.count))
            }
            while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 {
                SherpaOnnxDecodeOnlineStream(recognizer, stream)
            }
            s.lastText = Self.text(recognizer, stream)
            if s.t0 == nil, !s.lastText.isEmpty { s.t0 = max(0, s.tLast - 0.5) }
            let f = Self.finalize(&s)
            SherpaOnnxOnlineStreamReset(recognizer, stream)
            return f
        }
        if let out { continuation.yield(out) }
    }

    public func stop() async {
        await finishUtterance()
        continuation.finish()
    }

    /// Evaluation on pre-segmented corpora: decodes one segment with the same
    /// model, settings and 0.8 s tail padding as the live path, without endpoint resets inside the segment, and leaves
    /// the stream reset for the next segment. Not used by the app.
    public func transcribeSegment(_ samples: [Int16]) -> String {
        state.withLock { s in
            guard let stream = s.stream else { return "" }
            let floats = samples.map { Float($0) / 32768 } + [Float](repeating: 0, count: 12_800)
            floats.withUnsafeBufferPointer {
                SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, $0.baseAddress, Int32($0.count))
            }
            SherpaOnnxOnlineStreamInputFinished(stream)
            while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 {
                SherpaOnnxDecodeOnlineStream(recognizer, stream)
            }
            let text = Self.text(recognizer, stream)
            SherpaOnnxDestroyOnlineStream(stream)  // a finished stream takes no more input: start a fresh one
            s.stream = SherpaOnnxCreateOnlineStream(recognizer)
            (s.lastText, s.t0) = ("", nil)
            return Self.tidy(text)
        }
    }

    private static func finalize(_ s: inout State) -> ASRResult? {
        defer { (s.lastText, s.t0) = ("", nil) }
        let text = tidy(s.lastText)
        guard !text.isEmpty, let t0 = s.t0 else { return nil }
        return ASRResult(text: text, isFinal: true, t0: t0, t1: s.tLast, engine: engineName)
    }

    private static func text(_ r: OpaquePointer, _ stream: OpaquePointer) -> String {
        guard let result = SherpaOnnxGetOnlineStreamResult(r, stream) else { return "" }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }
        return String(cString: result.pointee.text).trimmingCharacters(in: .whitespaces)
    }

    /// The model emits upper case without punctuation; store sentence case.
    static func tidy(_ s: String) -> String {
        let lower = s.lowercased().trimmingCharacters(in: .whitespaces)
        guard let first = lower.first else { return "" }
        return first.uppercased() + lower.dropFirst()
    }
}

/// Emits scripted results for pipeline tests (no model).
public final class ScriptedRecognizer: StreamingRecognizer, @unchecked Sendable {
    public let results: AsyncStream<ASRResult>
    private let continuation: AsyncStream<ASRResult>.Continuation
    private let script: Mutex<[String]>
    private let span = Mutex<(t0: TimeInterval?, t1: TimeInterval)>((nil, 0))

    /// Each `finishUtterance()` emits the next scripted line as a final result spanning the frames fed since.
    public init(lines: [String]) {
        script = Mutex(lines)
        (results, continuation) = AsyncStream.makeStream()
    }
    public func start(locale: Locale) async throws {}
    public func feed(_ frame: PCMFrame) {
        span.withLock { s in
            if s.t0 == nil, frame.rms > 0.01 { s.t0 = frame.timestamp }  // like a real model: starts with speech
            if s.t0 != nil { s.t1 = frame.timestamp + 0.02 }
        }
    }
    public func finishUtterance() async {
        let (t0, t1) = span.withLock { s in
            defer { s.t0 = nil }
            return (s.t0, s.t1)
        }
        guard let t0, let line = script.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { return }
        continuation.yield(ASRResult(text: line, isFinal: true, t0: t0, t1: t1, engine: "scripted"))
    }
    public func stop() async { continuation.finish() }
}
