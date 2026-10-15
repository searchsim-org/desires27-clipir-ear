import EarCore
import SwiftUI

/// P2.7: live partial line, final segments, pin/unpin, forget, retention, debug export.
struct TranscriptView: View {
    @Bindable var model: AppModel
    @State private var forgotten: Int?

    var body: some View {
        NavigationStack {
            List {
                if !model.partialText.isEmpty {
                    Text(model.partialText).italic().foregroundStyle(.secondary).accessibilityIdentifier("partialLine")
                }
                ForEach(model.segments.reversed()) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(s.speaker).font(.caption.bold())
                            Text(s.wallClock, style: .relative).font(.caption).foregroundStyle(.secondary)
                            if s.pinned { Image(systemName: "pin.fill").font(.caption).accessibilityLabel("Pinned") }
                        }
                        Text(s.text)
                    }
                    .swipeActions {
                        Button(s.pinned ? "Unpin" : "Pin") { Task { await model.togglePin(s) } }.tint(.orange)
                    }
                }
                if model.segments.isEmpty && model.partialText.isEmpty {
                    Text("Nothing heard yet. Start listening on the Listening tab.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Transcript")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Keep transcript for", selection: $model.retentionMinutes) {
                            Text("1 minute").tag(1)
                            Text("5 minutes").tag(5)
                            Text("30 minutes").tag(30)
                            Text("1 hour").tag(60)
                            Text("24 hours").tag(1440)
                        }
                        #if DEBUG
                            ShareLink("Export transcript (debug)", item: model.exportJSONL())
                        #endif
                    } label: {
                        Label("Options", systemImage: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Forget last 10 min", role: .destructive) {
                        Task { forgotten = await model.forgetLast(minutes: 10) }
                    }
                    .accessibilityIdentifier("forgetButton")
                }
            }
            .alert("Forgot \(forgotten ?? 0) segments", isPresented: .constant(forgotten != nil)) {
                Button("OK") { forgotten = nil }
            }
        }
    }
}
