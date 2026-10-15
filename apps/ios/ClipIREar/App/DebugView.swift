import EarCore
import SwiftUI

/// Settings → Debug: audio route, models, capture statistics and the egress ledger (P1.6, §2.5).
struct DebugView: View {
    var model: AppModel

    var body: some View {
        List {
            Section("Route") {
                ForEach(model.route.inputs, id: \.self) { Text("in: \($0)") }
                ForEach(model.route.outputs, id: \.self) { Text("out: \($0)") }
            }
            Section("Models") { Text("LLM: \(model.llm.rawValue)") }
            Section("Capture") {
                LabeledContent("Source", value: model.sourceLabel)
                LabeledContent("Level", value: String(format: "%.2f", model.level))
                LabeledContent("Input sample rate", value: "\(Int(model.stats.inputSampleRate)) Hz")
                LabeledContent("Frames/s (target 50)", value: "\(model.framesPerSecond)")
                LabeledContent("Frames received", value: "\(model.stats.framesEmitted)")
                LabeledContent("Dropped frames", value: "\(model.stats.droppedFrames)")
            }
            Section("Network (EgressGuard ledger)") {
                let entries = ConnectionLedger.shared.all()
                if entries.isEmpty { Text("No connections").foregroundStyle(.secondary) }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                    Text("\(e.allowed ? "✓" : "✗") \(e.host)")
                }
            }
        }
    }
}
