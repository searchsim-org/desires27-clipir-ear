import EarCore
import Foundation

/// macOS runner for EarCore (harness + development). Subcommands are added per phase.
@main
struct EarCLI {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { return usage() }
        args.removeFirst()
        do {
            switch command {
            case "version": print("EarCLI \(EarCore.version)")
            case "transcribe": try await transcribe(args)
            case "ask": try await ask(args)
            case "qa": try await qa(args)
            case "loop": try await loop(args)
            case "asr-stream": try await asrStream(args)
            case "tts-stream": try await ttsStream()
            case "asr-segments": try asrSegments()
            default: usage()
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func usage() {
        print(
            """
            usage: EarCLI version
                   EarCLI transcribe <wav> [--engine sherpa] [--locale en-US] [--vad silero|energy]
                   EarCLI ask --transcript <jsonl> --question "<q>" [--at <seconds>] [--answerer llama|tiny|mock] [--model <gguf>]
                   EarCLI loop --wav <fixture.wav> --queries <queries/en.json> [--model <gguf>] [--answerer tiny|mock] [--out <json>]
                   EarCLI asr-stream [--utterance]   (PCM16 16 kHz on stdin → JSON lines; used by earbridge, ADR-015)
                   EarCLI asr-segments   (stdin lines "<id>\t<file.pcm>" of PCM16 16 kHz → JSON lines {"id","text"}; corpus WER)
                   EarCLI tts-stream   (one sentence per stdin line → length-prefixed PCM16 24 kHz on stdout; earbridge)
                   EarCLI qa --fixture <name> [--fixtures <dir>] [--answerer llama|tiny|mock] [--model <gguf>] [--transcript <jsonl>]
            """)
        exit(2)
    }

    static func option(_ args: [String], _ name: String, default value: String) -> String {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return value }
        return args[i + 1]
    }

    /// Prints final segments as JSONL: {"t0","t1","text","engine"} (P2.8).
    static func transcribe(_ args: [String]) async throws {
        guard let path = args.first, !path.hasPrefix("--") else { return usage() }
        let engine = option(args, "--engine", default: "sherpa")
        guard engine == "sherpa" else { throw EarError.model("engine \(engine) unavailable (ADR-008: sherpa only)") }
        let locale = Locale(identifier: option(args, "--locale", default: "en-US"))
        let vad: any VoiceActivityDetector =
            option(args, "--vad", default: "silero") == "energy" ? EnergyVAD() : try SileroVAD()
        let store = try SQLiteTranscriptStore.inMemory()
        let session = try await store.startSession(SessionInfo(captureSource: "file", deviceModel: "mac"))
        let pipeline = AmbientPipeline(store: store, vad: vad, recognizer: try SherpaStreamingRecognizer(numThreads: 4))
        let printer = Task {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            for await s in pipeline.finals {
                let line = [
                    "t0": String(format: "%.2f", s.t0), "t1": String(format: "%.2f", s.t1), "text": s.text,
                    "engine": s.engine,
                ]
                print(String(data: try! enc.encode(line), encoding: .utf8)!)
            }
        }
        try await pipeline.run(
            source: FileCaptureSource(url: URL(fileURLWithPath: path), realtime: false),
            sessionID: session, locale: locale)
        await printer.value
    }

    // MARK: query path (P3.9, P3.10)

    static func answerer(_ args: [String]) throws -> any Answerer {
        switch option(args, "--answerer", default: "llama") {
        case "mock": return MockAnswerer()
        case "tiny": return try LlamaAnswerer.tiny()
        default:
            let model = option(args, "--model", default: Models.gemma4E2B)
            let path = model.hasPrefix("/") ? model : try Models.path(model)
            return LlamaAnswerer(modelPath: path)
        }
    }

    /// Loads JSONL segments ({"t0","t1","text"}) into a fresh in-memory store.
    static func storeFrom(transcript path: String) async throws -> SQLiteTranscriptStore {
        let store = try SQLiteTranscriptStore.inMemory()
        let session = try await store.startSession(SessionInfo(captureSource: "file", deviceModel: "mac"))
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") where !line.isEmpty {
            let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let t0 = Double("\(o["t0"]!)")!
            let t1 = Double("\(o["t1"]!)")!
            _ = try await store.append(
                Segment(
                    sessionID: session, t0: t0, t1: t1, text: o["text"] as! String, source: "file",
                    engine: "\(o["engine"] ?? "")"))
        }
        return store
    }

    struct QAResult: Encodable {
        let question: String, intent: String, answer: String, knowledgeTier: String, correct: Bool,
            mustContain: [String]
        let firstTokenSeconds: Double, totalSeconds: Double, promptTokens: Int, completionTokens: Int
    }

    static func runQuestion(
        _ q: String, at: Double?, store: SQLiteTranscriptStore, answerer: any Answerer,
        mustContain: [String] = []
    ) async throws -> QAResult {
        let intent = IntentDetector().detect(q)
        let ctx = try await ContextAssembler(store: store).assemble(question: q, intent: intent, at: at)
        var req = AnswerRequest(
            question: q, intent: intent, window: ctx.window, retrieved: ctx.retrieved, notes: ctx.notes)
        req.windowSeconds = ctx.windowSeconds
        req.minutes = ctx.minutes
        let start = Date()
        var first: Double?
        var text = ""
        var tier = "none"
        var tokens = (0, 0)
        for try await e in answerer.answer(req) {
            switch e {
            case .token(let t):
                if first == nil { first = Date().timeIntervalSince(start) }
                text += t
            case .knowledgeTier(let k): tier = k
            case .done(let p, let c): tokens = (p, c)
            default: break
            }
        }
        let answer = PromptBuilder.parseSource(text).answer
        let ok = mustContain.contains { answer.lowercased().contains($0.lowercased()) }
        return QAResult(
            question: q, intent: intent.rawValue, answer: answer, knowledgeTier: tier, correct: ok,
            mustContain: mustContain, firstTokenSeconds: first ?? 0, totalSeconds: Date().timeIntervalSince(start),
            promptTokens: tokens.0, completionTokens: tokens.1)
    }

    static func printJSON<T: Encodable>(_ v: T) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(data: try! enc.encode(v), encoding: .utf8)!)
    }

    static func ask(_ args: [String]) async throws {
        let transcript = option(args, "--transcript", default: "")
        let q = option(args, "--question", default: "")
        guard !transcript.isEmpty, !q.isEmpty else { return usage() }
        let store = try await storeFrom(transcript: transcript)
        let at = Double(option(args, "--at", default: ""))
        let a = try answerer(args)
        printJSON(try await runQuestion(q, at: at, store: store, answerer: a))
        (a as? LlamaAnswerer)?.unload()  // free Metal resources before exit (ggml asserts otherwise)
    }

    /// Asks every planted fact's question 5 s after the fact (HANDOVER P3.10) and prints one JSON line per fact.
    static func qa(_ args: [String]) async throws {
        let name = option(args, "--fixture", default: "lecture_en_01")
        let dir = URL(fileURLWithPath: option(args, "--fixtures", default: "Tests/Fixtures"))
        var transcript = option(args, "--transcript", default: "")
        if transcript.isEmpty {  // transcribe once with the real pipeline
            let store = try SQLiteTranscriptStore.inMemory()
            let session = try await store.startSession(SessionInfo(captureSource: "file", deviceModel: "mac"))
            try await AmbientPipeline(
                store: store, vad: try SileroVAD(), recognizer: try SherpaStreamingRecognizer(numThreads: 4)
            )
            .run(
                source: FileCaptureSource(url: dir.appendingPathComponent("\(name).wav"), realtime: false),
                sessionID: session)
            transcript = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).jsonl").path
            let lines = try await store.all(session: session).map { s in
                String(
                    data: try JSONSerialization.data(withJSONObject: [
                        "t0": s.t0, "t1": s.t1, "text": s.text, "engine": s.engine,
                    ]), encoding: .utf8)!
            }
            try (lines.joined(separator: "\n") + "\n").write(toFile: transcript, atomically: true, encoding: .utf8)
        }
        let store = try await storeFrom(transcript: transcript)
        struct Fact: Decodable {
            let t: Double
            let question: String
            let mustContain: [String]
            enum CodingKeys: String, CodingKey {
                case t, question
                case mustContain = "must_contain"
            }
        }  // swift-format-ignore
        let facts = try JSONDecoder().decode([Fact].self, from: Data(contentsOf: dir.appendingPathComponent("\(name).facts.json")))
        let a = try answerer(args)
        for f in facts {
            printJSON(
                try await runQuestion(f.question, at: f.t + 5, store: store, answerer: a, mustContain: f.mustContain))
        }
        (a as? LlamaAnswerer)?.unload()  // free Metal resources before exit (ggml asserts otherwise)
    }

    /// End-to-end loop (P4.7): the fixture plays in real time through the full ambient pipeline; each recorded
    /// question for that fixture is asked 5 s after its fact (like a PTT press), answered by the real LLM, spoken by
    /// SystemSpeaker into a silent real-time output. Prints one latency JSON object per query.
    static func loop(_ args: [String]) async throws {
        let wav = URL(fileURLWithPath: option(args, "--wav", default: "Tests/Fixtures/lecture_en_01.wav"))
        let queriesURL = URL(fileURLWithPath: option(args, "--queries", default: "Tests/Fixtures/queries/en.json"))
        struct Q: Decodable {
            let fixture: String
            let t: Double
            let question: String
            let wav: String
        }
        let fixture = wav.deletingPathExtension().lastPathComponent
        let queries = try JSONDecoder().decode([Q].self, from: Data(contentsOf: queriesURL)).filter {
            $0.fixture == fixture
        }
        let store = try SQLiteTranscriptStore.inMemory()
        let a = try answerer(args)
        // --mac host:port:token → Mac tier through a live earbridge (P5/P7 egress and Mac-tier latency runs)
        var config = PipelineConfig()
        var bridge: BridgeClient?
        let mac = option(args, "--mac", default: "")
        if !mac.isEmpty {
            let parts = mac.split(separator: ":").map(String.init)
            guard parts.count == 3, let port = Int(parts[1]) else { throw EarError.notFound("--mac host:port:token") }
            let b = BridgeClient(pairing: PairingInfo(host: parts[0], port: port, token: parts[2]))
            let events = await b.subscribe()
            await b.start()
            for await e in events { if case .connected = e { break } }
            bridge = b
            config.policy = TierPolicy(mode: .mac)
        }
        let p = EarPipeline(
            config: config,
            deps: PipelineDeps(
                store: store, makeSource: { FileCaptureSource(url: wav, realtime: true) }, makeVAD: { try SileroVAD() },
                makeRecognizer: { try SherpaStreamingRecognizer(numThreads: 2) }, answerer: a,
                speaker: SystemSpeaker(), output: try AudioOutput(sampleRate: 24_000, silent: true), bridge: bridge))
        if let l = a as? LlamaAnswerer { _ = try l.warm() }  // model kept warm while ambient mode is on (P3.5)
        let start = Date()
        try await p.startAmbient()
        for q in queries {
            let wait = q.t + 5 - Date().timeIntervalSince(start)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            await p.beginQuery()  // the push-to-talk path: question audio streamed in real time, Mac tier if paired
            try await p.feedQuestionAudio(
                url: queriesURL.deletingLastPathComponent().appendingPathComponent(q.wav), realtime: true)
            let h = try await p.endQuery()
            var text = ""
            for await e in h.events { if case .token(let t) = e { text += t } }
            try await Task.sleep(for: .milliseconds(100))  // let the pipeline persist the row
            let row = try await store.queries().last!
            var obj = try JSONSerialization.jsonObject(with: Data(row.latencyJSON.utf8)) as! [String: Any]
            (obj["fixture"], obj["question"], obj["asr_question"], obj["model"]) = (
                fixture, q.question, row.question, row.model
            )
            obj["answer"] = PromptBuilder.parseSource(text).answer
            print(
                String(data: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), encoding: .utf8)!)
        }
        await p.stopAmbient()
        await bridge?.stop()
        (a as? LlamaAnswerer)?.unload()
        // Every network destination the run touched (EgressGuard ledger, §2.5): evidence for docs/evidence/egress.md
        let ledger = ConnectionLedger.shared.all().map { ["host": $0.host, "allowed": $0.allowed] as [String: Any] }
        print(
            String(
                decoding: try JSONSerialization.data(withJSONObject: ["ledger": ledger], options: [.sortedKeys]),
                as: UTF8.self))
    }

    /// earbridge ASR worker (ADR-015): PCM16 mono 16 kHz on stdin → one JSON line per result on stdout:
    /// {"type":"partial"|"final","text","t0","t1","engine"}. Ambient mode runs VAD + streaming ASR; `--utterance`
    /// decodes one question until EOF (query.begin … query.end).
    static func asrStream(_ args: [String]) async throws {
        setvbuf(stdout, nil, _IOLBF, 0)  // line-buffered: earbridge reads results as they come
        func emit(_ type: String, _ r: ASRResult) {
            let o: [String: Any] = ["type": type, "text": r.text, "t0": r.t0, "t1": r.t1, "engine": r.engine]
            print(
                String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)!)
        }
        let recognizer = try SherpaStreamingRecognizer(numThreads: 2)
        let source = StdinCaptureSource()
        if args.contains("--utterance") {
            try await recognizer.start(locale: Locale(identifier: "en-US"))
            try await source.start()
            for i in 0..<15 {  // 300 ms lead-in, as on the phone
                recognizer.feed(
                    PCMFrame(
                        samples: Array(repeating: 0, count: 320), timestamp: Double(i) * 0.02 - 0.3, source: .remote))
            }
            let printer = Task { for await r in recognizer.results { emit(r.isFinal ? "final" : "partial", r) } }
            for await f in source.frames { recognizer.feed(f) }
            await recognizer.stop()
            await printer.value
            return
        }
        let store = try SQLiteTranscriptStore.inMemory()
        let session = try await store.startSession(SessionInfo(captureSource: "remote", deviceModel: "mac"))
        let pipeline = AmbientPipeline(store: store, vad: try SileroVAD(), recognizer: recognizer)
        let partials = Task { for await r in pipeline.partials { emit("partial", r) } }
        let finals = Task {
            for await s in pipeline.finals {
                emit("final", ASRResult(text: s.text, isFinal: true, t0: s.t0, t1: s.t1, engine: s.engine))
            }
        }
        try await pipeline.run(source: source, sessionID: session)
        await partials.value
        await finals.value
    }

    /// Corpus evaluation: one recognizer, one segment per stdin line.
    static func asrSegments() throws {
        let asr = try SherpaStreamingRecognizer(numThreads: 4)
        let enc = JSONEncoder()
        while let line = readLine() {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let data = FileManager.default.contents(atPath: parts[1]) else { continue }
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            let out = ["id": parts[0], "text": asr.transcribeSegment(samples)]
            print(String(data: try enc.encode(out), encoding: .utf8)!)
            fflush(stdout)
        }
    }

    /// earbridge TTS worker (ADR-015): a warm SystemSpeaker. Each stdin line is one sentence; stdout gets frames of
    /// [UInt32 LE byte count][PCM16 mono 24 kHz], and a zero-length frame after each sentence.
    static func ttsStream() async throws {
        let speaker = SystemSpeaker()
        let out = FileHandle.standardOutput
        func frame(_ samples: [Int16]) {
            var n = UInt32(samples.count * 2).littleEndian
            var data = Data(bytes: &n, count: 4)
            samples.withUnsafeBytes { data.append(contentsOf: $0) }
            out.write(data)
        }
        while let line = readLine() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                for await chunk in speaker.synthesize(text) {
                    frame(AudioOutput.resample(chunk.samples, from: chunk.sampleRate, to: 24_000))
                }
            }
            frame([])
        }
    }
}
