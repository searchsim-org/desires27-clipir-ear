import EarCore
import SwiftUI

/// The app's one main screen (replaces the Listening and Ask tabs). Each state has one obvious action: idle →
/// Start listening; listening → hold to ask, or tap a quick question; answering → the answer card with Stop / Say again.
/// Everything else (transcript, review, record, forget, settings) is in the ⋯ menu.
struct HomeView: View {
    @Bindable var model: AppModel
    @State private var sheet: Sheet?
    @State private var answerDismissed = false

    enum Sheet: String, Identifiable {
        case transcript, review, settings
        var id: String { rawValue }
    }

    /// Typed questions that go through the same routing, retrieval and voice as spoken ones.
    static let quickQuestions: [(icon: String, text: String)] = [
        ("text.bubble", "What did they just say?"),
        ("clock.arrow.circlepath", "What did I miss in the last two minutes?"),
        ("lightbulb", "Explain that in simple words"),
        ("list.bullet", "What are the key points so far?"),
    ]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            LinearGradient(colors: [Theme.magenta.opacity(0.35), .clear], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                header
                if let banner = bannerText { bannerView(banner) }
                if let action = model.pendingAction {
                    approvalCard(action)
                } else if model.isListening || showsAnswer {
                    listeningStage
                } else {
                    idleStage
                }
                Spacer(minLength: 0)
                if model.isListening && !model.isAsking && model.pendingAction == nil { quickQuestionRow }
                actionBar
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
        .sheet(item: $sheet) { s in
            switch s {
            case .transcript: TranscriptView(model: model)
            case .review: ReviewView(model: model)
            case .settings: MacView(model: model)
            }
        }
        .onChange(of: model.question) { answerDismissed = false }
    }

    private var showsAnswer: Bool {  // from the moment a question exists, so asking never looks like nothing happened
        !answerDismissed && (model.isAnswering || !model.answerText.isEmpty || !model.question.isEmpty)
    }

    // MARK: header: name, state in words, the menu

    private var header: some View {
        HStack(spacing: 10) {
            LogoMark(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("ClipIR Ear").font(.headline).foregroundStyle(.white)
                HStack(spacing: 6) {
                    Circle().fill(model.isListening ? Theme.cyan : .white.opacity(0.35)).frame(width: 7, height: 7)
                    Text(statusLine).font(.caption).foregroundStyle(.white.opacity(0.7))
                        .accessibilityIdentifier("statusLine")
                }
            }
            Spacer()
            if model.isRecording {
                Label("REC", systemImage: "record.circle.fill").font(.caption.bold()).foregroundStyle(.red)
                    .accessibilityLabel("Recording audio")
            }
            menu
        }
    }

    private var statusLine: String {
        guard model.isListening else { return "Paused · nothing is being heard" }
        return "Listening · kept \(model.retentionMinutes) min, on this phone"
    }

    private var menu: some View {
        Menu {
            Button("Transcript", systemImage: "text.quote") { sheet = .transcript }
            Button("Review and export", systemImage: "tray.full") { sheet = .review }
            if model.isListening && !model.fieldStudy {  // P8.3: explicit Record; never in the field study
                Button(
                    model.isRecording ? "Stop recording" : "Record audio",
                    systemImage: model.isRecording ? "stop.fill" : "record.circle", action: model.toggleRecording)
            }
            if !AppModel.fixtureQuestions.isEmpty && model.isListening {
                Menu("Ask a recorded question", systemImage: "waveform") {
                    ForEach(AppModel.fixtureQuestions, id: \.self) { q in
                        Button("\(q.fixture): \(q.question)") { model.askFixture(q) }
                    }
                }
            }
            Button("Forget the last 10 minutes", systemImage: "eraser", role: .destructive) { model.shakePurge() }
            if model.isListening {
                Button("Stop listening", systemImage: "stop.circle") { model.toggle() }
            }
            Button("Settings", systemImage: "gearshape") { sheet = .settings }
        } label: {
            Image(systemName: "ellipsis").font(.title3).foregroundStyle(.white)
                .frame(width: 42, height: 42).overlay(Circle().stroke(Theme.pink.opacity(0.6)))
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("moreMenu")
    }

    private var bannerText: String? {
        if let e = model.errorText { return e }
        switch model.health {
        case .ok: return nil
        case .interrupted(let r): return "Listening paused: \(r)"
        case .ended(let r): return "Listening stopped. Tap Start listening to resume. (\(r))"
        }
    }

    private func bannerView(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Theme.orange.opacity(0.18), in: .rect(cornerRadius: 12))
            .accessibilityIdentifier("healthBanner")
    }

    // MARK: idle

    private var idleStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Missed something?").font(.system(size: 40, weight: .bold)).foregroundStyle(.white)
            Text("Start listening, then ask about what was just said. Answers play in your earbuds.")
                .font(.body).foregroundStyle(.white.opacity(0.7))
            SunStripes().frame(width: 180, height: 180).frame(maxWidth: .infinity).padding(.top, 24)
        }
        .padding(.top, 28)
    }

    // MARK: listening and answering

    private var listeningStage: some View {
        VStack(spacing: 16) {
            SunStripes(level: model.level, active: model.isListening)
                .frame(width: showsAnswer ? 110 : 190, height: showsAnswer ? 110 : 190)
                .overlay {
                    if model.isAsking {
                        Text("Your turn").font(.caption.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Theme.background.opacity(0.7), in: .capsule)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: showsAnswer)
            if showsAnswer { answerCard } else { liveText }
        }
        .padding(.top, 12)
    }

    private var liveText: some View {
        VStack(spacing: 10) {
            Text(model.isAsking ? "Ask your question…" : liveLine)
                .font(.system(size: 23, weight: .semibold)).foregroundStyle(.white)
                .multilineTextAlignment(.center).lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 92)
                .accessibilityIdentifier("liveLine")
            if !model.isAsking {
                ForEach(contextLines, id: \.self) { line in
                    Text(line).font(.footnote).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
                if !model.segments.isEmpty {
                    Button("See the full transcript") { sheet = .transcript }
                        .font(.footnote.bold()).foregroundStyle(Theme.cyan)
                }
            }
        }
    }

    private var liveLine: String {
        if !model.partialText.isEmpty { return model.partialText }
        return model.segments.last?.text ?? "Waiting for speech…"
    }

    /// The two lines before the live one, for context.
    private var contextLines: [String] {
        let texts = model.segments.map(\.text)
        let before = model.partialText.isEmpty ? texts.dropLast() : texts[...]
        return Array(before.suffix(2))
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(model.question.isEmpty ? "Your question" : model.question)
                    .font(.subheadline.bold()).foregroundStyle(Theme.orange).accessibilityIdentifier("question")
                Spacer()
                Button {
                    answerDismissed = true
                } label: {
                    Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.white.opacity(0.6))
                }
                .accessibilityLabel("Close answer")
            }
            Text(answerBody)
                .font(.body).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(9).accessibilityIdentifier("answer")
            HStack(spacing: 12) {
                if !model.knowledgeTier.isEmpty {
                    Label(
                        model.knowledgeTier == "transcript" ? "From the talk" : "General knowledge",
                        systemImage: model.knowledgeTier == "transcript" ? "waveform" : "book"
                    )
                    .font(.caption).foregroundStyle(Theme.cyan).accessibilityIdentifier("knowledgeTier")
                }
                if !model.answerVoice.isEmpty {
                    Label(model.answerVoice, systemImage: "person.wave.2")
                        .font(.caption).foregroundStyle(Theme.cyan).accessibilityIdentifier("answerVoice")
                }
                Spacer()
                if model.isAnswering {
                    Button("Stop", systemImage: "stop.fill", action: model.cancel)
                } else {
                    Button("Say again", systemImage: "speaker.wave.2", action: model.sayAgain)
                }
            }
            .font(.subheadline.bold()).foregroundStyle(Theme.orange)
            LatencyChips(latency: model.latency, cached: model.repeatedFromCache, demo: model.demoMode)
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(16).background(Theme.panel, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.sea, lineWidth: 1.5))
    }

    private var answerBody: String {
        if !model.answerText.isEmpty { return model.answerText }
        return model.isAnswering ? "Thinking…" : "No answer came back. Try asking again, or open the transcript."
    }

    /// P6.2: a proposed action waits for a spoken "yes"; on screen too, e.g. where nobody can speak.
    private func approvalCard(_ action: EarAction) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Waiting for your OK").font(.caption.bold()).foregroundStyle(Theme.cyan)
            Text(action.proposal).font(.title3.weight(.semibold)).foregroundStyle(.white)
                .accessibilityIdentifier("proposal")
            HStack(spacing: 12) {
                Button("Yes") { model.respond("yes") }
                    .font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Theme.hot, in: .capsule)
                Button("No") { model.respond("no") }
                    .font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 12)
                    .overlay(Capsule().stroke(.white.opacity(0.4)))
            }
            Text("Or say “yes” or “no”.").font(.caption).foregroundStyle(.white.opacity(0.5))
        }
        .padding(18).background(Theme.panel, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.sea, lineWidth: 1.5))
        .padding(.top, 24)
    }

    // MARK: quick questions

    private var quickQuestionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick questions").font(.caption.bold()).foregroundStyle(.white.opacity(0.5))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Self.quickQuestions, id: \.text) { q in
                        Button {
                            model.ask(text: q.text)
                        } label: {
                            Label(q.text, systemImage: q.icon).font(.footnote).foregroundStyle(.white).lineLimit(1)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(Theme.panel, in: .capsule)
                                .overlay(Capsule().stroke(Theme.pink.opacity(0.55)))
                        }
                        .disabled(model.isAnswering)
                        .opacity(model.isAnswering ? 0.4 : 1)
                    }
                }
            }
        }
    }

    // MARK: the main action for the current state

    @ViewBuilder private var actionBar: some View {
        if model.isListening {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(askTitle).font(.headline).foregroundStyle(.white)
                    Text(askHint).font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Circle().fill(model.isAsking ? AnyShapeStyle(Theme.sea) : AnyShapeStyle(Theme.hot))
                    .frame(width: 64, height: 64)
                    .overlay(Image(systemName: "mic.fill").font(.title2).foregroundStyle(.white))
                    .scaleEffect(model.isAsking ? 1.12 : 1).animation(.spring(duration: 0.25), value: model.isAsking)
                    .modifier(PushToTalk(model: model))
                    .accessibilityElement().accessibilityAddTraits(.isButton)
                    .accessibilityLabel(model.isAsking ? "Send question" : "Ask a question")
                    .accessibilityHint("Double-tap to start a question, double-tap again to send it")
                    .accessibilityAction { model.isAsking ? model.pttUp() : model.pttDown() }  // VoiceOver cannot hold
                    .accessibilityIdentifier("pttButton")
            }
            .padding(.leading, 20).padding(6)
            .background(Theme.panel, in: .capsule)
            .overlay(Capsule().stroke(Theme.sun, lineWidth: 1))
        } else {
            Button(action: model.requestStart) {
                Label("Start listening", systemImage: "ear").font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                    .background(Theme.hot, in: .capsule)
            }
            .accessibilityIdentifier("listenButton")
        }
    }

    private var askTitle: String {
        if model.tapToToggle { return model.isAsking ? "Tap to send" : "Tap to ask" }
        return model.isAsking ? "Release to send" : "Hold to ask"
    }

    private var askHint: String {
        model.isAsking ? "Speak your question now" : "or press your earbud stem once"
    }
}

/// Hold to ask (or tap to start and tap to send, with "Tap to talk" on in Settings).
private struct PushToTalk: ViewModifier {
    var model: AppModel
    func body(content: Content) -> some View {
        if model.tapToToggle {
            content.onTapGesture { model.isAsking ? model.pttUp() : model.pttDown() }
        } else {
            content.gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in model.pttDown() }
                    .onEnded { _ in model.pttUp() })
        }
    }
}

/// Debug chips (P4.6): earcon and first audio relative to the end of the question, then done.
struct LatencyChips: View {
    var latency: [Stage: TimeInterval]
    var cached = false
    var demo = false

    var body: some View {
        #if DEBUG
            chips
        #else
            if demo { chips }  // P7.3: demo mode shows them in release builds too
        #endif
    }

    private var chips: some View {
        let end = latency[.speechEnd] ?? 0
        return HStack(spacing: 8) {
            ForEach([(Stage.earcon, "earcon"), (.audioOutStart, "first audio"), (.done, "done")], id: \.1) { s, label in
                if let v = latency[s] {
                    Text("\(label) \(String(format: "%.2f", v - end)) s").font(.caption2.monospacedDigit())
                }
            }
            if cached { Text("cached").font(.caption2.bold()) }
        }
    }
}
