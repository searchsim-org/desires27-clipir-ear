import EventKit
import XCTest

@testable import EarCore

/// P7.4 on EarSim: the demo scenario (docs/DEMO.md, simulator variant) ten times in one process — ambient lecture,
/// two recorded questions, a spoken reminder approved with "yes", "forget the last ten minutes", export. Every step
/// must produce its output; footprint is logged per run to catch leaks. Device version: a device check.
final class DemoStabilityTest: XCTestCase {
    func testDemoScenarioTenTimes() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["EAR_STABILITY"] == "1", "opt-in: make stability")
        let dir = URL(fileURLWithPath: try XCTUnwrap(env["CLIPIR_EAR_FIXTURES"]))
        let ek = EKEventStore()
        let canRemind = (try? await ek.requestFullAccessToReminders()) == true
        let answerer = try LlamaAnswerer.tiny()
        var footprints: [Double] = []
        for run in 1...10 {
            let store = try SQLiteTranscriptStore.inMemory()
            let p = EarPipeline(
                config: PipelineConfig(),
                deps: PipelineDeps(
                    store: store,
                    makeSource: {
                        FileCaptureSource(url: dir.appendingPathComponent("lecture_en_02.wav"), realtime: false)
                    },
                    makeVAD: { try SileroVAD() }, makeRecognizer: { try SherpaStreamingRecognizer() },
                    answerer: answerer,
                    speaker: SystemSpeaker(), output: try AudioOutput(sampleRate: 24_000, silent: true)))
            try await p.startAmbient()
            await p.waitUntilAmbientEnds()
            let segments = try await store.count()
            XCTAssertGreaterThan(segments, 20, "run \(run): ambient transcript")
            for q in ["lecture_en_02_q03", "lecture_en_02_q07"] {
                await p.beginQuery()
                try await p.feedQuestionAudio(url: dir.appendingPathComponent("queries/\(q).wav"))
                let h = try await p.endQuery()
                var text = ""
                for await e in h.events { if case .token(let t) = e { text += t } }
                XCTAssertFalse(text.isEmpty, "run \(run): answer to \(q)")
            }
            if canRemind {
                let title = "read the paper \(run)-\(UUID().uuidString.prefix(4))"
                let h = try await p.ask(question: "remind me to \(title) tomorrow at nine")
                await p.respondToApproval("yes")
                var last = ""
                for await e in h.events { if case .sentence(let s) = e { last = s } }
                XCTAssertEqual(last, "Reminder created.", "run \(run): reminder")
                let ids: [String] = await withCheckedContinuation { c in
                    ek.fetchReminders(matching: ek.predicateForReminders(in: nil)) { rs in
                        c.resume(returning: (rs ?? []).filter { $0.title == title }.map(\.calendarItemIdentifier))
                    }
                }
                for id in ids {
                    if let r = ek.calendarItem(withIdentifier: id) as? EKReminder { try? ek.remove(r, commit: true) }
                }
            }
            let f = try await p.ask(question: "forget the last ten minutes")
            for await _ in f.events {}
            let left = try await store.count()
            XCTAssertEqual(left, 0, "run \(run): forget")
            let sessions = try await Exporter(store: store).sessions()
            let session = try XCTUnwrap(sessions.first?.id)
            let doc = try await Exporter(store: store).export(session: session)
            XCTAssertNotNil(doc["measures"], "run \(run): export")
            footprints.append(DeviceTelemetry.footprintMB)
            print("stability run \(run): ok, footprint \(Int(DeviceTelemetry.footprintMB)) MB")
        }
        answerer.unload()
        print("stability-result", footprints.map { Int($0) })
        XCTAssertLessThan(footprints.last! - footprints[1], 300, "no large growth across runs (MB)")
    }
}
