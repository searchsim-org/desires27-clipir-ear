import EarTTSKokoro
import XCTest

@testable import ClipIREar
@testable import EarCore

final class AppSmokeTests: XCTestCase {
    func testAppLinksEarCore() {
        XCTAssertFalse(EarCore.version.isEmpty)
    }

    func testInfoPlistDeclaresPrivacyAndBackgroundKeys() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)  // hosted test: main bundle is the app
        XCTAssertNotNil(info["NSMicrophoneUsageDescription"])
        XCTAssertNotNil(info["NSBluetoothAlwaysUsageDescription"])
        XCTAssertEqual(info["UIBackgroundModes"] as? [String], ["audio", "bluetooth-central"])
    }

    /// ADR-020: Kokoro renders on the phone (MLX aborts creating its Metal device in the simulator).
    func testKokoroSpeaksOneSentenceOnTheDevice() async throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("MLX does not run in the simulator")
        #else
            let k: KokoroSpeaker
            do { k = try KokoroSpeaker(voice: KokoroSpeaker.defaultVoice) } catch {
                throw XCTSkip("Kokoro model missing")
            }
            let pcm = try await k.render("The bridge was built in eleven forty.")
            XCTAssertGreaterThan(pcm.count, KokoroSpeaker.sampleRate)  // more than a second of audio
        #endif
    }
}
