import XCTest

@testable import EarCore

/// P7.1 soak: lecture fixtures back to back in real time through the full ambient pipeline (Silero + Zipformer +
/// store + retention + embeddings) for SOAK_MINUTES (default 30). Logs footprint, thermal state and battery every
/// minute and attaches them as JSON. On a device this is A4/A5 evidence; on EarSim it only shows stability and
/// footprint trend (opt in with TEST_RUNNER_EAR_SOAK=1; `make soak`).
final class AmbientSoak: XCTestCase {
    func testThirtyMinuteAmbientRun() async throws {
        let env = ProcessInfo.processInfo.environment
        #if targetEnvironment(simulator)
            try XCTSkipUnless(env["EAR_SOAK"] == "1", "simulator soak is opt-in: make soak")
        #endif
        let minutes = Double(env["SOAK_MINUTES"] ?? "30") ?? 30
        let dir = URL(fileURLWithPath: try XCTUnwrap(env["CLIPIR_EAR_FIXTURES"]))
        let wavs = [
            "lecture_en_01", "lecture_en_02", "lecture_en_03", "lecture_en_04", "lecture_en_05", "meeting_en_01",
        ]
        .map { dir.appendingPathComponent("\($0).wav") }
        let source = PlaylistSource(urls: wavs, totalSeconds: minutes * 60)
        let store = try SQLiteTranscriptStore.inMemory()
        let p = EarPipeline(
            config: PipelineConfig(),
            deps: PipelineDeps(
                store: store, makeSource: { source }, makeVAD: { try SileroVAD() },
                makeRecognizer: { try SherpaStreamingRecognizer() }, answerer: MockAnswerer(), embedder: HashEmbedder())
        )
        let start = Date()
        try await p.startAmbient()
        var samples: [[String: Any]] = []
        let battery0 = await DeviceTelemetry.batteryLevel
        while Date().timeIntervalSince(start) < minutes * 60 + 5 {
            try await Task.sleep(for: .seconds(60))
            let n = try await store.count()
            let row: [String: Any] = [
                "minute": Int(Date().timeIntervalSince(start) / 60),
                "footprint_mb": DeviceTelemetry.footprintMB.rounded(),
                "thermal": DeviceTelemetry.thermalState, "battery": await DeviceTelemetry.batteryLevel as Any,
                "segments": n,
            ]
            samples.append(row)
            print("soak", row)
        }
        await p.stopAmbient()
        let frames = source.framesEmitted
        let expected = Int(minutes * 60 * 50)
        let result: [String: Any] = [
            "minutes": minutes, "samples": samples, "frames": frames, "expected_frames": expected,
            "battery_start": battery0 as Any, "battery_end": await DeviceTelemetry.batteryLevel as Any,
            "platform": ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "device",
        ]
        let a = XCTAttachment(
            data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
            uniformTypeIdentifier: "public.json")
        a.name = "AmbientSoak"
        a.lifetime = .keepAlways
        add(a)
        print(
            "soak-result",
            String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        XCTAssertGreaterThan(Double(frames) / Double(expected), 0.99, "dropped frames < 1 %")
        XCTAssertFalse(samples.contains { $0["thermal"] as? String == "critical" })
        XCTAssertLessThan(samples.compactMap { $0["footprint_mb"] as? Double }.max() ?? 0, 3584)
    }
}

/// Plays files back to back in real time until `totalSeconds` (loops the playlist).
final class PlaylistSource: CaptureSource, @unchecked Sendable {
    let id = CaptureSourceID.file("soak-playlist")
    let frames: AsyncStream<PCMFrame>
    private let continuation: AsyncStream<PCMFrame>.Continuation
    private let urls: [URL]
    private let total: TimeInterval
    private let lock = NSLock()
    private var emitted = 0
    private var task: Task<Void, Never>?
    var framesEmitted: Int { lock.withLock { emitted } }

    init(urls: [URL], totalSeconds: TimeInterval) {
        (self.urls, total) = (urls, totalSeconds)
        (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func start() async throws {
        let (urls, total, c) = (urls, total, continuation)
        task = Task { [weak self] in
            let clock = ContinuousClock()
            let anchor = clock.now
            var t = 0.0
            var i = 0
            while t < total, !Task.isCancelled {
                let file = FileCaptureSource(url: urls[i % urls.count], realtime: false)
                try? await file.start()
                for await f in file.frames {
                    if t >= total || Task.isCancelled { break }
                    try? await clock.sleep(until: anchor + .seconds(t + 0.02))
                    c.yield(PCMFrame(samples: f.samples, timestamp: t, source: .file("soak")))
                    self?.lock.withLock { self?.emitted += 1 }
                    t += 0.02
                }
                i += 1
            }
            c.finish()
        }
    }

    func stop() async {
        task?.cancel()
        continuation.finish()
    }
}
