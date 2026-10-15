import SwiftUI

/// P8.1: consent (short form of docs/study/consent.md), retention choice, the orange indicator. Shown once.
struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var page = 0
    @State private var minutes = 30

    var body: some View {
        VStack(spacing: 20) {
            TabView(selection: $page) {
                pageView(
                    "ear", "Listens, keeps text, not audio",
                    "While Listening is on, ClipIR Ear turns speech around you into a short transcript on this phone. "
                        + "Audio is not stored unless you press Record. Voices are not identified and emotions are "
                        + "never inferred."
                ).tag(0)
                VStack(spacing: 16) {
                    pageHeader("clock.arrow.circlepath", "How long to keep the transcript")
                    Picker("Keep transcript for", selection: $minutes) {
                        Text("1 min").tag(1)
                        Text("10 min").tag(10)
                        Text("30 min").tag(30)
                        Text("2 h").tag(120)
                        Text("24 h").tag(1440)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("retentionPicker")
                    Text(
                        "1 min keeps almost nothing. Shake the phone, tap Forget, or say \u{201C}forget the last ten minutes\u{201D} at any time."
                    )
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding().tag(1)
                pageView(
                    "mic.fill", "The orange dot is expected",
                    "iOS shows an orange microphone indicator whenever the app listens, and a Listening Live "
                        + "Activity appears on the lock screen. Nothing leaves your devices except to your own paired "
                        + "Mac, and study exports contain derived measures you review first."
                ).tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            Button(page < 2 ? "Continue" : "I agree, start using ClipIR Ear") {
                if page < 2 {
                    withAnimation { page += 1 }
                } else {
                    model.setRetention(minutes: minutes)
                    model.onboarded = true
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("onboardingNext")
            Text("Voice enrolment for \u{201C}you\u{201D} labels comes with the device build.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
    }

    private func pageHeader(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 48)).foregroundStyle(.orange).accessibilityHidden(true)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
        }
    }

    private func pageView(_ icon: String, _ title: String, _ body: String) -> some View {
        VStack(spacing: 16) {
            pageHeader(icon, title)
            Text(body).multilineTextAlignment(.center)
        }
        .padding()
    }
}
