import AVFoundation
import EarCore
import EarTTSKokoro
import SwiftUI

/// P5.7: pairing (QR or code), status chip, tier policy, Forget Mac, stem PTT trade-off.
struct MacView: View {
    /// "af_heart" → "Heart · US female"; Kokoro's names encode accent (a/b) and gender (f/m).
    static func kokoroLabel(_ id: String) -> String {
        let parts = id.split(separator: "_", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].count == 2 else { return id }
        let accent = parts[0].first == "b" ? "UK" : "US"
        let gender = parts[0].last == "m" ? "male" : "female"
        return "\(parts[1].capitalized) · \(accent) \(gender)"
    }

    static func voiceLabel(_ v: AVSpeechSynthesisVoice) -> String {
        "\(v.name) · \(v.language) · \(SystemSpeaker.qualityName(v.quality))"
    }

    @Bindable var model: AppModel
    @State private var host = ""
    @State private var code = ""
    @State private var scanning = false
    @State private var error: String?
    @State private var kokoroVoices: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(
                        model.macStatus,
                        systemImage: model.macConnected ? "laptopcomputer.and.iphone" : "laptopcomputer.slash"
                    )
                    .foregroundStyle(model.macConnected ? .green : .secondary)
                    .accessibilityIdentifier("macStatus")
                }
                Section("Answer with") {
                    Picker("Tier", selection: $model.tierMode) {
                        Text("Auto (Mac when close by)").tag(TierPolicy.Mode.auto)
                        Text("Phone only").tag(TierPolicy.Mode.phone)
                        Text("Mac (phone if unreachable)").tag(TierPolicy.Mode.mac)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if model.pairing == nil {
                    Section("Pair with earbridge") {
                        Text(
                            "On your Mac run `earbridge pair`, then scan the code or type the address and the 8-character code."
                        )
                        .font(.footnote).foregroundStyle(.secondary)
                        if AVCaptureDevice.default(for: .video) != nil {
                            Button("Scan pairing code") { scanning = true }
                        }
                        TextField("Mac address (e.g. 192.168.1.20)", text: $host)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        TextField("Code", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Button("Pair") {
                            if let p = PairingInfo.manual(host: host, code: code) {
                                model.pair(p)
                            } else {
                                error = "Enter the Mac address and the 8-character code."
                            }
                        }
                        if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                    }
                } else {
                    Section {
                        Button("Forget Mac", role: .destructive, action: model.forgetMac)
                    }
                }
                Section {
                    Picker(
                        "Keep transcript for",
                        selection: Binding(get: { model.retentionMinutes }, set: { model.setRetention(minutes: $0) })
                    ) {
                        Text("1 minute").tag(1)
                        Text("10 minutes").tag(10)
                        Text("30 minutes").tag(30)
                        Text("2 hours").tag(120)
                        Text("24 hours").tag(1440)
                    }
                    Toggle("Proactive cues", isOn: $model.cuesEnabled).accessibilityIdentifier("cuesToggle")
                    if model.cuesEnabled {
                        Text(
                            model.cueKeywords.isEmpty
                                ? "No cue words yet. Say \u{201C}note this: …\u{201D} or pin a transcript line; its words become cue words."
                                : "Listening for: \(model.cueKeywords.joined(separator: ", "))"
                        )
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("cueWords")
                        .task { await model.loadCueKeywords() }
                    }
                } header: {
                    Text("Privacy and cues")
                } footer: {
                    Text(
                        "Cues whisper a word from your notes or pinned lines when someone says it, at most 6 an hour. "
                            + "Shake the phone to forget the last 10 minutes.")
                }
                Section("Listening and asking") {
                    Picker("Listen to", selection: $model.sourceKind) {
                        Text("Microphone").tag(AppModel.SourceKind.microphone)
                        ForEach(AppModel.fixtureNames, id: \.self) {  // simulator: recorded lectures (ADR-010)
                            Text("Recording: \($0)").tag(AppModel.SourceKind.fixture($0))
                        }
                    }
                    .disabled(model.isListening)
                    .accessibilityIdentifier("sourcePicker")
                    Picker("Answer with", selection: $model.llm) {
                        ForEach(AppModel.LLM.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Tap to talk (instead of hold)", isOn: $model.tapToToggle)
                }
                Section {
                    Picker("Voice", selection: $model.kokoroVoice) {
                        Text("Off: use the Apple voice").tag(String?.none)
                        ForEach(kokoroVoices, id: \.self) { Text(Self.kokoroLabel($0)).tag(Optional($0)) }
                    }
                    .accessibilityIdentifier("kokoroVoicePicker")
                    Picker("Fallback voice", selection: $model.appleVoiceID) {
                        Text(
                            "Best installed: \(SystemSpeaker.bestVoice().map { "\($0.name), \(SystemSpeaker.qualityName($0.quality))" } ?? "default")"
                        )
                        .tag(String?.none)
                        ForEach(SystemSpeaker.voices(), id: \.identifier) { v in
                            Text(Self.voiceLabel(v)).tag(Optional(v.identifier))
                        }
                    }
                    .accessibilityIdentifier("voicePicker")
                    Button("Preview voice", systemImage: "speaker.wave.2", action: model.previewVoice)
                } header: {
                    Text("Answer voice")
                } footer: {
                    Text(
                        "Kokoro runs on this phone. If its files are missing, it is too slow, or the phone runs short "
                            + "of memory, the fallback voice speaks instead. For a better fallback, download a Premium "
                            + "English voice in Settings → Accessibility → Spoken Content → Voices.")
                }
                .task { kokoroVoices = KokoroSpeaker.installedVoices() }
                Section {
                    Toggle("Demo mode", isOn: $model.demoMode)
                    NavigationLink("Debug (route, frames, network ledger)") { DebugView(model: model) }
                } footer: {
                    Text("Demo mode pre-loads the models, pauses automatic forgetting and shows the latency chips.")
                }
                Section {
                    Toggle("AirPods stem press asks a question", isOn: $model.stemPTTEnabled)
                } footer: {
                    Text(
                        "While listening, ClipIR Ear becomes the now-playing app so the stem press reaches it. "
                            + "That takes play/pause away from your music app until you stop listening.")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $scanning) {
                QRScanner { text in
                    scanning = false
                    if let p = PairingInfo.fromQR(text) {
                        model.pair(p)
                    } else {
                        error = "That code is not an earbridge pairing code."
                    }
                }
            }
        }
    }
}

/// Camera QR reader (P5.5). Device only: the simulator has no camera.
struct QRScanner: UIViewControllerRepresentable {
    var found: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.found = found
        return c
    }

    func updateUIViewController(_ c: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var found: ((String) -> Void)?
        private let session = AVCaptureSession()

        override func viewDidLoad() {
            super.viewDidLoad()
            guard let device = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            nonisolated(unsafe) let session = session  // startRunning blocks; Apple: call it off the main thread
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            MainActor.assumeIsolated {  // delegate queue is .main (setMetadataObjectsDelegate above)
                session.stopRunning()
                found?(text)
            }
        }
    }
}
