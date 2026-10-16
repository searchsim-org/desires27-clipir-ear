import AVFoundation
import ActivityKit
import EarCore
import EarTTSKokoro
import Foundation
import MediaPlayer
import Observation
import UIKit
import UserNotifications
import os

private let log = Logger(subsystem: "de.zerhoudi.clipir-ear", category: "app")

/// The app's single owner of the pipeline (P1.5–P3.8). Views read and call this; EarCore does the work.
@MainActor
@Observable
final class AppModel {
    enum SourceKind: Hashable {
        case microphone
        case fixture(String)  // Tests/Fixtures/<name>.wav played in real time (simulator demo, ADR-010)
    }

    enum LLM: String, CaseIterable, Identifiable {
        case gemma = "Gemma 4 E2B"
        case qwen = "Qwen3 1.7B"
        case tiny = "Qwen3 0.6B (tiny)"
        var id: String { rawValue }
        var file: String {
            switch self {
            case .gemma: Models.gemma4E2B
            case .qwen: Models.qwen3Phone
            case .tiny: Models.qwen3CI
            }
        }
    }

    // Listening
    var isListening = false
    var sourceKind: SourceKind = .microphone
    var route = AudioRouteState()
    var health: SessionHealth = .ok
    var level: Float = 0
    var errorText: String?
    var stats = MicCaptureSource.Stats.zero
    var framesPerSecond = 0

    // Transcript
    var partialText = ""
    var segments: [Segment] = []
    var retentionMinutes = 30 {
        didSet {
            retention = RetentionPolicy(store: store, retentionSeconds: Double(retentionMinutes) * 60)
            retention.start()
        }
    }

    // Ask
    var llm: LLM
    var isAsking = false  // PTT held
    var isAnswering = false
    var tapToToggle = false
    /// ADR-021: web search from this phone with the user's own Brave Search key (Keychain); off by default.
    var webSearchEnabled = UserDefaults.standard.bool(forKey: "earWebSearch") {
        didSet {
            UserDefaults.standard.set(webSearchEnabled, forKey: "earWebSearch")
            EgressGuard.shared.setWebSearch(enabled: webSearchEnabled && hasBraveKey)
        }
    }
    private(set) var hasBraveKey = Keychain.read(AppModel.braveKeyAccount) != nil
    nonisolated static let braveKeyAccount = "brave-search-api-key"
    var question = ""
    var answerText = ""
    var answerVoice = ""  // which voice spoke the last answer: "Kokoro", "Apple voice", "Mac"
    var knowledgeTier = ""
    var latency: [Stage: TimeInterval] = [:]
    var spokenSentences: [String] = []  // P4.6: what has been handed to the voice, in order
    var pendingAction: EarAction?  // P6.2: waiting for yes / no
    var repeatedFromCache = false
    var stemPTTEnabled = true

    /// P7.3 demo mode: models pre-warmed, retention purges paused, latency chips shown (also in release builds).
    var demoMode = UserDefaults.standard.bool(forKey: "earDemo") {
        didSet {
            UserDefaults.standard.set(demoMode, forKey: "earDemo")
            applyDemoMode()
        }
    }

    // Study hardening (Phase 8)
    var onboarded =
        UserDefaults.standard.bool(forKey: "earOnboarded") || UserDefaults.standard.bool(forKey: "earAutostart")
    {
        didSet { UserDefaults.standard.set(onboarded, forKey: "earOnboarded") }
    }
    var cuesEnabled = UserDefaults.standard.bool(forKey: "earCues") {  // P8.6: off by default
        didSet {
            UserDefaults.standard.set(cuesEnabled, forKey: "earCues")
            let p = pipeline
            let on = cuesEnabled
            Task { await p?.setCues(enabled: on) }
        }
    }
    var cueKeywords: [String] = []  // what cues listen for (Settings shows it)
    /// Field-study build: StGB §201 setting rule, no Record.
    let fieldStudy = UserDefaults.standard.bool(forKey: "earFieldStudy")
    var askingSetting = false  // the "Where are you?" dialog
    var sessionSettings: [String: Int] =
        (UserDefaults.standard.dictionary(forKey: "earSettings") as? [String: Int]) ?? [:]
    /// The Apple voice: the fallback when Kokoro is off, missing or failing (ADR-020); nil = best installed voice.
    var appleVoiceID = UserDefaults.standard.string(forKey: "earVoice") {
        didSet { UserDefaults.standard.set(appleVoiceID, forKey: "earVoice") }
    }
    /// The Kokoro voice for answers (ADR-020); nil = Kokoro off (stored as "off"). Never chosen: the default voice
    /// when its files are on the phone.
    var kokoroVoice: String? = {
        switch UserDefaults.standard.string(forKey: "earKokoroVoice") {
        case "off": return nil
        case let v?: return v
        case nil:
            let d = KokoroSpeaker.defaultVoice
            return KokoroSpeaker.installedVoices().contains(d) ? d : nil
        }
    }()
    {
        didSet { UserDefaults.standard.set(kokoroVoice ?? "off", forKey: "earKokoroVoice") }
    }
    /// Set by a memory warning: no pipeline built after it loads Kokoro again, until the next launch.
    private var kokoroDisabledThisLaunch = false
    private var speaker: FallbackSpeaker?
    private var kokoro: KokoroSpeaker?  // the pipeline's; Preview reuses it instead of loading the weights twice
    private let previewSpeaker = AVSpeechSynthesizer()
    private var previewOutput: AudioOutput?

    static var kokoroAllowedHere: Bool {
        #if targetEnvironment(simulator)
            false  // ADR-020: MLX aborts creating its Metal device in the simulator
        #else
            true
        #endif
    }

    /// The Kokoro voice this pipeline should use, if any.
    private var activeKokoroVoice: String? {
        guard Self.kokoroAllowedHere, !kokoroDisabledThisLaunch else { return nil }
        return kokoroVoice
    }

    /// Settings → Answer voice → Preview: one line with the voice that would answer now.
    func previewVoice() {
        let line = "The speaker said the bridge was built in eleven forty."
        previewSpeaker.stopSpeaking(at: .immediate)
        if let v = activeKokoroVoice {
            Task {
                let k = kokoro?.voice == v ? kokoro : try? KokoroSpeaker(voice: v)
                guard let k, let pcm = try? await k.render(line), !pcm.isEmpty,
                    let out = try? AudioOutput(sampleRate: KokoroSpeaker.sampleRate)
                else { return previewApple(line) }  // AVSpeechSynthesizer cannot play Kokoro's audio
                previewOutput = out
                out.enqueue(AudioChunk(samples: pcm, sampleRate: KokoroSpeaker.sampleRate))
            }
        } else {
            previewApple(line)
        }
    }

    private func previewApple(_ line: String) {
        let u = AVSpeechUtterance(string: line)
        u.voice = appleVoiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? SystemSpeaker.bestVoice()
        previewSpeaker.speak(u)
    }

    var isRecording = false  // P8.3
    var recordings: [URL] = []
    var purgeToast: String?
    private var activity: Activity<ListeningActivity>?
    private let metrics: MetricsIntake

    static var recordingsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings")
    }

    // Mac tier (P5.7)
    var pairing: PairingInfo? = PairingStore.load()
    var macStatus = "Not paired"
    var macConnected = false
    var macRTT: TimeInterval?
    var tierMode: TierPolicy.Mode =
        TierPolicy.Mode(rawValue: UserDefaults.standard.string(forKey: "tierMode") ?? "") ?? .auto
    {
        didSet { UserDefaults.standard.set(tierMode.rawValue, forKey: "tierMode") }
    }
    private var bridge: BridgeClient?

    let store: SQLiteTranscriptStore
    private var retention: RetentionPolicy
    private let session = AudioSessionManager()
    private var pipeline: EarPipeline?
    private var pipelineKey = ""
    private var tasks: [Task<Void, Never>] = []
    private let stem = StemPTT()

    static var fixturesDirectory: String? { ProcessInfo.processInfo.environment["CLIPIR_EAR_FIXTURES"] }
    static var fixtureNames: [String] {
        guard let dir = fixturesDirectory else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".wav") && !$0.contains("_snr") }
            .map { String($0.dropLast(4)) }.sorted()
    }

    struct FixtureQuestion: Decodable, Hashable {
        let fixture: String, question: String, wav: String, t: Double
    }
    static var fixtureQuestions: [FixtureQuestion] {
        guard let dir = fixturesDirectory,
            let data = FileManager.default.contents(atPath: dir + "/queries/en.json")
        else { return [] }
        return (try? JSONDecoder().decode([FixtureQuestion].self, from: data)) ?? []
    }

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // ponytail: a broken database file is a crash at launch; reset-on-corruption comes with Phase 8 onboarding.
        store = try! SQLiteTranscriptStore.file(at: dir.appendingPathComponent("ear.db"))
        retention = RetentionPolicy(store: store, retentionSeconds: 1800)
        metrics = MetricsIntake(store: store)
        metrics.start()  // P8.5
        let defaults = UserDefaults.standard
        if let m = defaults.object(forKey: "earRetentionMinutes") as? Int {  // didSet does not run in init
            retentionMinutes = m
            retention = RetentionPolicy(store: store, retentionSeconds: Double(m) * 60)
        }
        // ADR-014; also in the simulator, where Qwen3-0.6B often returned no answer text (2026-10-15)
        llm = LLM(rawValue: defaults.string(forKey: "earModel") ?? "") ?? .gemma
        EgressGuard.shared.setWebSearch(enabled: webSearchEnabled && hasBraveKey)
        retention.start()
        if let src = defaults.string(forKey: "earSource"), src.hasPrefix("fixture:") {
            sourceKind = .fixture(String(src.dropFirst("fixture:".count)))
        }
        if let json = defaults.string(forKey: "earPair"), let p = PairingInfo.fromQR(json) {  // scripted pairing
            try? PairingStore.save(p)
            pairing = p
        }
        tasks.append(Task { [weak self, session] in for await h in session.health { self?.handle(h) } })
        tasks.append(Task { [weak self, session] in for await r in session.routes { self?.route = r } })
        tasks.append(
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: UIApplication.didReceiveMemoryWarningNotification)
                {
                    self?.memoryWarning()
                }
            })
        tasks.append(
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: UIApplication.willEnterForegroundNotification)
                {
                    _ = try? await self?.retention.runOnce()
                    await self?.reloadSegments()
                }
            })
        stem.onToggle = { [weak self] in self?.stemPressed() }
        Task { await reloadSegments() }
        connectMac()
        applyDemoMode()
        if defaults.bool(forKey: "earAutostart") { start() }
        // Scripted demo/evidence runs: -earAutoAsk lecture_en_02_q03 -earAutoAskAfter 45 (seconds after launch)
        if let wav = defaults.string(forKey: "earAutoAsk"),
            let q = Self.fixtureQuestions.first(where: { $0.wav == wav + ".wav" })
        {
            let delay = max(1, defaults.double(forKey: "earAutoAskAfter"))
            Task {
                try? await Task.sleep(for: .seconds(delay))
                askFixture(q, at: q.t + 5)
            }
        }
    }

    var sourceLabel: String {
        if case .fixture(let n) = sourceKind { return "Fixture: \(n)" }
        return route.inputName
    }

    // MARK: pipeline

    private func currentPipeline() -> EarPipeline {
        let key =
            "\(sourceKind)|\(llm.rawValue)|\(tierMode.rawValue)|\(pairing?.host ?? "-")|\(appleVoiceID ?? "best")|\(kokoroVoice ?? "apple")|\(webSearchEnabled && hasBraveKey)"
        if let pipeline, key == pipelineKey { return pipeline }
        let kind = sourceKind
        let fixtures = Self.fixturesDirectory ?? ""
        let answerer: any Answerer = (try? Models.path(llm.file)).map { LlamaAnswerer(modelPath: $0) } ?? MockAnswerer()
        let deps = PipelineDeps(
            store: store,
            makeSource: {
                switch kind {
                case .microphone: return MicCaptureSource()
                case .fixture(let name):
                    return FileCaptureSource(
                        url: URL(fileURLWithPath: fixtures).appendingPathComponent("\(name).wav"), realtime: true)
                }
            },
            makeVAD: { try SileroVAD() },
            makeRecognizer: { try SherpaStreamingRecognizer() },
            answerer: answerer, embedder: try? LlamaEmbedder(),
            speaker: speakerForPipeline(), output: try? AudioOutput(sampleRate: 24_000),
            bridge: bridge,
            executor: EarActionExecutor(
                store: store,
                search: webSearchEnabled && hasBraveKey
                    ? BraveSearch(key: { Keychain.read(AppModel.braveKeyAccount) }) : nil,
                answerer: answerer))
        var config = PipelineConfig()
        config.deviceModel = UIDevice.current.model
        config.policy = TierPolicy(mode: tierMode)
        config.tierPolicy = tierMode.rawValue
        let p = EarPipeline(config: config, deps: deps)
        pipeline = p
        pipelineKey = key
        let cues = cuesEnabled
        Task { await p.setCues(enabled: cues) }
        tasks.append(Task { [weak self] in for await t in p.partials { self?.partialText = t } })
        tasks.append(
            Task { [weak self] in
                for await s in p.finals {
                    self?.segments.append(s)
                    self?.partialText = ""
                }
            })
        tasks.append(
            Task { [weak self] in for await l in p.levels { self?.level = 0.7 * (self?.level ?? 0) + 0.3 * l } })
        tasks.append(Task { [weak self] in for await s in p.state { self?.pipelineState(s) } })
        return p
    }

    private func pipelineState(_ s: PipelineState) {
        switch s {
        case .idle:
            if isListening { stopUI() }
        case .ended(let reason): handle(.ended(reason: reason))
        case .awaitingApproval(let a): pendingAction = a
        case .listening, .speaking, .answering: break
        default: break
        }
    }

    func toggle() { isListening ? stop() : requestStart() }

    /// Every user-initiated start goes through here: in the field-study build the setting must be one where speech is
    /// public or everyone present agreed; "other" never starts.
    func requestStart() {
        guard fieldStudy else { return start() }
        askingSetting = true
    }

    func startIn(setting: String) {
        askingSetting = false
        sessionSettings[setting, default: 0] += 1  // counted for the study export; no content
        UserDefaults.standard.set(sessionSettings, forKey: "earSettings")
        guard setting != "other" else {
            errorText = "Not started: use ClipIR Ear only in public talks or where everyone present agreed."
            return
        }
        start()
    }

    func start() {
        log.info("start source=\(String(describing: self.sourceKind), privacy: .public)")
        errorText = nil
        do {
            try session.activate(
                capture: sourceKind == .microphone, remoteControls: stemPTTEnabled && sourceKind == .microphone)
            if !UserDefaults.standard.bool(forKey: "earAutostart") {  // scripted runs: no permission prompt
                Task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                }  // a completion closure here inherits @MainActor and traps when iOS calls it off the main queue
            }
        } catch {
            errorText = "Audio session failed: \(error.localizedDescription)"
            return
        }
        let p = currentPipeline()
        isListening = true
        startActivity()
        if stemPTTEnabled, sourceKind == .microphone { stem.start() }  // stem PTT only matters with a live mic
        tasks.append(
            Task { [weak self] in  // Debug screen: frames/s and drops, once a second
                var last = 0
                while let self, self.isListening {
                    try? await Task.sleep(for: .seconds(1))
                    guard let s = await p.captureStats() else { continue }
                    self.framesPerSecond = s.framesEmitted - last
                    last = s.framesEmitted
                    self.stats = s
                }
            })
        Task {
            do { try await p.startAmbient() } catch {
                errorText = "Could not start listening: \(error)"
                stopUI()
            }
        }
    }

    func stop() {
        let p = pipeline
        stopUI()
        Task { await p?.stopAmbient() }
    }

    private func stopUI() {
        if isRecording { toggleRecording() }
        isListening = false
        if kokoroDisabledThisLaunch, kokoro != nil { releaseKokoro() }  // memory warning came while listening
        endActivity()
        level = 0
        partialText = ""
        stem.stop()
        session.deactivate()
    }

    private func handle(_ h: SessionHealth) {
        health = h
        guard case .ended = h, isListening else { return }
        stop()
        health = h
        let content = UNMutableNotificationContent()
        content.title = "Listening stopped"
        content.body = "Tap to resume."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "listening-stopped", content: content, trigger: nil))
    }

    // MARK: ask (P3.8)

    func pttDown() {
        guard isListening, !isAsking else { return }
        isAsking = true
        haptic(.medium)  // P8.2: felt with the earcon
        resetAnswer()
        let p = currentPipeline()
        Task { await p.beginQuery() }
    }

    func pttUp() {
        guard isAsking else { return }
        isAsking = false
        haptic(.light)
        let p = currentPipeline()
        run { try await p.endQuery() }
    }

    private func stemPressed() {
        if isAsking { pttUp() } else if isAnswering { cancel() } else { pttDown() }
    }

    /// A question given as text (quick-question chips): same routing, retrieval, answer and voice as a spoken one.
    func ask(text: String) {
        guard isListening, !isAnswering else { return }
        resetAnswer()
        let p = currentPipeline()
        run { try await p.ask(question: text) }
    }

    /// `at`: pipeline time to ask "about" (default: now, i.e. the latest transcript).
    func askFixture(_ q: FixtureQuestion, at: TimeInterval? = nil) {
        guard let dir = Self.fixturesDirectory else { return }
        resetAnswer()
        let p = currentPipeline()
        let url = URL(fileURLWithPath: dir + "/queries/" + q.wav)
        run {
            guard at == nil else { return try await p.askFromAudio(url: url, at: at) }  // scripted "about time t"
            await p.beginQuery()  // the same path as a held PTT button (Mac tier included)
            try await p.feedQuestionAudio(url: url, realtime: true)
            return try await p.endQuery()
        }
    }

    /// On-screen answer to a spoken proposal (P6.2), e.g. on the simulator where nobody can say "yes".
    func respond(_ text: String) {
        let p = currentPipeline()
        pendingAction = nil
        Task { await p.respondToApproval(text) }
    }

    /// "Say again": the last answer, from the cache, no model call (P4.4).
    func sayAgain() {
        let p = currentPipeline()
        repeatedFromCache = true
        Task { await p.repeatLastAnswer() }
    }

    func cancel() {
        let p = pipeline
        Task { await p?.cancelSpeech() }
        isAnswering = false
    }

    private func resetAnswer() {
        (question, answerText, answerVoice, knowledgeTier, latency) = ("", "", "", "", [:])
        spokenSentences = []
        repeatedFromCache = false
    }

    private func run(_ makeHandle: @escaping () async throws -> QueryHandle) {
        isAnswering = true
        Task {
            let before = (speaker?.spokenByPrimary ?? 0, speaker?.spokenByFallback ?? 0)
            defer { answerVoice = answerVoice.isEmpty ? voiceSince(before) : answerVoice }
            do {
                let h = try await makeHandle()
                question = h.question
                for await e in h.events {
                    switch e {
                    case .token(let t): answerText += t
                    case .knowledgeTier(let k): knowledgeTier = k
                    case .sentence(let s): spokenSentences.append(s)
                    case .tier("mac"): answerVoice = "Mac"  // the Mac's own TTS audio
                    default: break
                    }
                    latency = h.trace.export()
                }
                answerText = PromptBuilder.parseSource(answerText).answer
                // action flows speak only
                if answerText.isEmpty { answerText = spokenSentences.joined(separator: " ") }
                latency = h.trace.export()
                pendingAction = nil
            } catch {
                answerText = "I didn't catch a question."
                log.error("ask: \(String(describing: error), privacy: .public)")
            }
            isAnswering = false
        }
    }

    private func applyDemoMode() {
        guard demoMode else {
            retention.start()
            return
        }
        retention.stop()  // nothing disappears mid-demo; "Forget last 10 min" still works
        let llmPath = try? Models.path(llm.file)
        let voice = appleVoiceID
        Task.detached(priority: .utility) {  // warm the LLM and the voice before the first question
            if let llmPath { _ = try? LlamaAnswerer(modelPath: llmPath).warm() }
            for await _ in SystemSpeaker(voiceIdentifier: voice).synthesize(" ") {}
        }
    }

    // MARK: Mac tier (P5.5, P5.7)

    /// Connects to the paired Mac (if any) and keeps the status chip current.
    func connectMac() {
        guard let pairing, bridge == nil else { return }
        let b = BridgeClient(pairing: pairing)
        bridge = b
        pipeline = nil  // rebuilt with the bridge on next use
        tasks.append(
            Task { [weak self] in
                let events = await b.subscribe()
                await b.start()
                self?.macStatus = "Connecting to \(pairing.name ?? pairing.host)…"
                for await e in events {
                    switch e {
                    case .connected(let server):
                        self?.macConnected = true
                        self?.macStatus = "Mac: \(pairing.name ?? pairing.host) · \(server)"
                    case .rtt(let r):
                        self?.macRTT = r
                        self?.macStatus = "Mac: \(pairing.name ?? pairing.host) · \(Int(r * 1000)) ms"
                    case .disconnected(let reason):
                        self?.macConnected = false
                        self?.macStatus = "Mac unreachable (\(reason.prefix(40)))"
                    default: break
                    }
                }
            })
    }

    func pair(_ p: PairingInfo) {
        try? PairingStore.save(p)
        pairing = p
        disconnectMac()
        connectMac()
    }

    func forgetMac() {
        PairingStore.forget()
        disconnectMac()
        pairing = nil
        macStatus = "Not paired"
    }

    private func disconnectMac() {
        let b = bridge
        bridge = nil
        pipeline = nil
        macConnected = false
        Task { await b?.stop() }
    }

    // MARK: web search (ADR-021)

    /// Settings → Web search → Save: keeps the key in this iPhone's Keychain and switches search on.
    func saveBraveKey(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, Keychain.save(key, account: Self.braveKeyAccount) else { return }
        hasBraveKey = true
        webSearchEnabled = true
    }

    func removeBraveKey() {
        Keychain.delete(account: Self.braveKeyAccount)
        hasBraveKey = false
        webSearchEnabled = false
    }

    // MARK: answer voice (ADR-020)

    /// Which voice spoke the sentences since `before` (FallbackSpeaker's counts; playback has finished by now).
    private func voiceSince(_ before: (Int, Int)) -> String {
        let kokoro = (speaker?.spokenByPrimary ?? 0) - before.0
        let apple = (speaker?.spokenByFallback ?? 0) - before.1
        switch (kokoro > 0, apple > 0) {
        case (true, false): return "Kokoro"
        case (false, true): return "Apple voice"
        case (true, true): return "Kokoro + Apple voice"
        default: return ""
        }
    }

    /// Kokoro when chosen and loadable, else the Apple voice; FallbackSpeaker covers a slow or failing Kokoro.
    private func speakerForPipeline() -> Speaker {
        let apple = SystemSpeaker(voiceIdentifier: appleVoiceID)
        // ponytail: loads ~330 MB on the main actor once per pipeline build; move off-main if the stall is felt
        kokoro = nil  // drop the old weights before loading new ones
        kokoro = activeKokoroVoice.flatMap { try? KokoroSpeaker(voice: $0) }
        kokoro?.warmUp()
        let s = FallbackSpeaker(primary: kokoro, fallback: apple)
        speaker = s
        return s
    }

    /// iOS is short of memory: speak with the Apple voice from now on and never load Kokoro again this launch.
    /// While listening the pipeline (and Kokoro's weights) stays alive; stopUI releases them.
    private func memoryWarning() {
        log.info("memory warning: answer voice falls back to Apple for this launch")
        speaker?.markPrimaryUnhealthy()
        kokoroDisabledThisLaunch = true
        if !isListening { releaseKokoro() }
    }

    /// Frees Kokoro's weights and MLX's buffers; the next pipeline build speaks with the Apple voice.
    private func releaseKokoro() {
        pipeline = nil
        speaker = nil
        kokoro = nil
        KokoroSpeaker.releaseCaches()
    }

    // MARK: study hardening (Phase 8)

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    /// P8.3: explicit Record. Only while listening; red state in the app and the Live Activity.
    func toggleRecording() {
        guard let p = pipeline else { return }
        if isRecording {
            isRecording = false
            Task {
                await p.stopRecording()
                loadRecordings()
            }
        } else {
            guard isListening, !fieldStudy else { return }  // no audio recording in the field study
            let name = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = Self.recordingsDirectory.appendingPathComponent("\(name).wav")
            Task {
                do {
                    try await p.startRecording(to: url)
                    isRecording = true
                    updateActivity()
                } catch { errorText = "Could not start recording: \(error.localizedDescription)" }
            }
        }
        haptic(.rigid)
        updateActivity()
    }

    func loadCueKeywords() async {
        let notes = ((try? await store.notes()) ?? []).map(\.text)
        let pinned = ((try? await store.pinned()) ?? []).map(\.text)
        cueKeywords = CueEngine.keywords(from: notes + pinned).sorted()
    }

    func loadRecordings() {
        recordings =
            ((try? FileManager.default.contentsOfDirectory(
                at: Self.recordingsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func deleteRecording(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        loadRecordings()
    }

    /// P8.2 / PRIVACY §10.3: shaking the phone forgets the last 10 minutes.
    func shakePurge() {
        Task {
            let n = await forgetLast(minutes: 10)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            purgeToast = "Forgot the last 10 minutes (\(n) segment\(n == 1 ? "" : "s"))."
        }
    }

    func setRetention(minutes: Int) {
        retentionMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: "earRetentionMinutes")
    }

    private func startActivity() {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(
            attributes: ListeningActivity(startedAt: Date()),
            content: .init(state: activityState, staleDate: nil))
    }

    private func updateActivity() {
        guard let activity else { return }
        let state = activityState
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    private func endActivity() {
        guard let a = activity else { return }
        activity = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }

    private var activityState: ListeningActivity.ContentState {
        .init(recording: isRecording, retentionMinutes: retentionMinutes)
    }

    // MARK: transcript actions (P2.7)

    func reloadSegments() async { segments = (try? await store.all()) ?? [] }

    func forgetLast(minutes: Int) async -> Int {
        let n = (try? await store.purge(lastSeconds: Double(minutes) * 60)) ?? 0
        await reloadSegments()
        return n
    }

    func togglePin(_ s: Segment) async {
        guard let id = s.id else { return }
        try? await store.pin(id, !s.pinned)
        await reloadSegments()
    }

    /// Debug-only JSONL export of the current segments (device check).
    func exportJSONL() -> URL {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        let lines = segments.compactMap { try? enc.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcript.jsonl")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// AirPods stem press as push-to-talk (P3.1): while listening, the app plays a silent loop so it is the now-playing
/// app and receives play/pause. Trade-off (shown in Settings): it takes over play/pause from music apps.
@MainActor
final class StemPTT {
    var onToggle: (() -> Void)?
    private var player: AVAudioPlayer?
    private var target: Any?

    func start() {
        guard player == nil else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000  // one second of zeros
            try? AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1
        player?.play()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "ClipIR Ear — listening"]
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.isEnabled = true
        target = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.onToggle?() }
            return .success
        }
    }

    func stop() {
        player?.stop()
        player = nil
        if let target { MPRemoteCommandCenter.shared().togglePlayPauseCommand.removeTarget(target) }
        target = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

/// Generic-password Keychain item for this app, readable after the first unlock and never synced off the phone.
enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "clipir-ear",
            kSecAttrAccount as String: account,
        ]
    }

    static func read(_ account: String) -> String? {
        var q = query(account)
        (q[kSecReturnData as String], q[kSecMatchLimit as String]) = (true, kSecMatchLimitOne)
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    @discardableResult static func save(_ value: String, account: String) -> Bool {
        delete(account: account)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String) { SecItemDelete(query(account) as CFDictionary) }
}
