import EarCore
import SwiftUI

/// P6.4: sessions with derived measures, opt-in toggles, export via the share sheet; notes.
struct ReviewView: View {
    var model: AppModel
    @State private var sessions: [Exporter.SessionSummary] = []
    @State private var notes: [Note] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Sessions") {
                    if sessions.isEmpty { Text("No sessions yet.").foregroundStyle(.secondary) }
                    ForEach(sessions) { s in
                        NavigationLink {
                            SessionExportView(store: model.store, session: s)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(s.startedAt, format: .dateTime.day().month().hour().minute())
                                Text("\(s.queryCount) questions · \(s.segmentCount) segments · \(s.captureSource)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Recordings") {  // P8.3
                    if model.recordings.isEmpty {
                        Text("Nothing recorded. Audio is kept only when you press Record.").foregroundStyle(.secondary)
                    }
                    ForEach(model.recordings, id: \.self) { url in
                        ShareLink(item: url) {
                            Label(url.deletingPathExtension().lastPathComponent, systemImage: "waveform")
                        }
                        .swipeActions { Button("Delete", role: .destructive) { model.deleteRecording(url) } }
                    }
                }
                Section("Notes") {
                    if notes.isEmpty { Text("Say \"note this\" to keep something.").foregroundStyle(.secondary) }
                    ForEach(notes, id: \.id) { n in
                        VStack(alignment: .leading) {
                            Text(n.text)
                            Text(n.createdAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(
                                .secondary)
                        }
                    }
                }
            }
            .navigationTitle("Review")
            .task {
                model.loadRecordings()
                sessions = (try? await Exporter(store: model.store).sessions()) ?? []
                notes = (try? await model.store.notes()) ?? []
            }
            .refreshable {
                sessions = (try? await Exporter(store: model.store).sessions()) ?? []
                notes = (try? await model.store.notes()) ?? []
            }
        }
    }
}

struct SessionExportView: View {
    let store: SQLiteTranscriptStore
    let session: Exporter.SessionSummary
    @State private var includeQA = false
    @State private var includeTranscript = false
    @State private var measures: [String: String] = [:]
    @State private var files: [URL] = []

    var body: some View {
        Form {
            Section("Derived measures") {
                ForEach(measures.keys.sorted(), id: \.self) { k in
                    LabeledContent(k.replacingOccurrences(of: "_", with: " "), value: measures[k] ?? "—")
                        .font(.footnote)
                }
            }
            Section {
                Toggle("Include questions and answers", isOn: $includeQA)
                Toggle("Include transcript", isOn: $includeTranscript)
            } footer: {
                Text(
                    "Off by default: the export then contains only counts, timings and settings — no words that were said."
                )
            }
            Section {
                Button("Prepare export") {
                    Task {
                        files =
                            (try? await Exporter(store: store).write(
                                session: session.id,
                                options: .init(
                                    includeQuestionsAndAnswers: includeQA, includeTranscript: includeTranscript))) ?? []
                    }
                }
                if !files.isEmpty {
                    ShareLink("Share JSON + summary", items: files)
                }
            }
        }
        .navigationTitle("Session")
        .task { measures = (try? await Exporter(store: store).measureSummary(session: session.id)) ?? [:] }
    }
}
