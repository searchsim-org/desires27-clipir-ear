import AVFoundation
import XCTest

@testable import EarCore

/// P1 simulator smoke test: the mic source delivers ≥ 50 frames in 2 s on EarSim (uses the Mac's microphone).
/// Needs microphone permission twice: inside the simulator (`make mic-smoke` grants it) and for the Simulator app
/// in macOS (System Settings → Privacy & Security → Microphone). Without the macOS grant, CoreAudio aborts the process
/// (AURemoteIO RPC timeout), so the test only runs when TEST_RUNNER_EARSIM_MIC=1 (set by `make mic-smoke`).
final class MicSmokeTest: XCTestCase {
    func testMicDeliversFramesOnSimulator() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EARSIM_MIC"] == "1", "opt-in: make mic-smoke")
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)
        let mic = MicCaptureSource()
        try await mic.start()
        let collector = Task {
            var n = 0
            for await _ in mic.frames { n += 1 }
            return n
        }
        try await Task.sleep(for: .seconds(2))
        await mic.stop()
        let frames = await collector.value
        XCTAssertGreaterThanOrEqual(frames, 50, "frames received in 2 s")
        XCTAssertTrue(mic.stats().inputSampleRate > 0)
    }
}
