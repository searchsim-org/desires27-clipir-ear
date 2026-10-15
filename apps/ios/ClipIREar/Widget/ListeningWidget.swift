import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ListeningWidgets: WidgetBundle {
    var body: some Widget { ListeningLiveActivity() }
}

struct ListeningLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ListeningActivity.self) { ctx in
            HStack {
                Image(systemName: ctx.state.recording ? "record.circle.fill" : "ear")
                    .foregroundStyle(ctx.state.recording ? .red : .orange)
                VStack(alignment: .leading) {
                    Text(ctx.state.recording ? "ClipIR Ear — recording" : "ClipIR Ear — listening").font(.headline)
                    Text("Transcript kept \(ctx.state.retentionMinutes) min, on this phone").font(.caption)
                }
                Spacer()
                Text(ctx.attributes.startedAt, style: .timer).monospacedDigit().font(.caption)
            }
            .padding()
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: ctx.state.recording ? "record.circle.fill" : "ear")
                }
                DynamicIslandExpandedRegion(.center) { Text(ctx.state.recording ? "Recording" : "Listening") }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(ctx.attributes.startedAt, style: .timer).monospacedDigit()
                }
            } compactLeading: {
                Image(systemName: ctx.state.recording ? "record.circle.fill" : "ear")
                    .foregroundStyle(ctx.state.recording ? .red : .orange)
            } compactTrailing: {
                Text(ctx.attributes.startedAt, style: .timer).monospacedDigit().frame(width: 44)
            } minimal: {
                Image(systemName: "ear").foregroundStyle(.orange)
            }
        }
    }
}
