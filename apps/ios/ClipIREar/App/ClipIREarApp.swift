import EarCore
import SwiftUI

@main
struct ClipIREarApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeView(model: model)
                .fullScreenCover(isPresented: .constant(!model.onboarded)) { OnboardingView(model: model) }
                .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in model.shakePurge() }
                .confirmationDialog("Where are you?", isPresented: $model.askingSetting, titleVisibility: .visible) {
                    Button("Public talk or lecture") { model.startIn(setting: "public") }
                    Button("Everyone here was told and agreed") { model.startIn(setting: "consented") }
                    Button("Somewhere else", role: .destructive) { model.startIn(setting: "other") }
                } message: {
                    Text("German law protects non-public speech. Listen only in public talks or where everyone agreed.")
                }
                .alert(
                    model.purgeToast ?? "",
                    isPresented: .init(get: { model.purgeToast != nil }, set: { _ in model.purgeToast = nil })
                ) {}
        }
    }
}
