import XCTest

@testable import EarCore

/// P2 simulator smoke test: lecture_en_01 through the real ambient pipeline (Silero + Zipformer) on EarSim;
/// ≥ 80 % of the planted facts must be findable with searchLexical. Models are read from the Mac's model folder
/// (Models.directory, SIMULATOR_HOST_HOME); fixtures from CLIPIR_EAR_FIXTURES (scheme test environment).
final class AmbientSmokeTest: XCTestCase {
    struct Fact: Decodable {
        let fact: String
        let mustContain: [String]
        enum CodingKeys: String, CodingKey {
            case fact
            case mustContain = "must_contain"
        }
    }

    func testPlantedFactsAreFindable() async throws {
        guard let dir = ProcessInfo.processInfo.environment["CLIPIR_EAR_FIXTURES"] else {
            throw XCTSkip("no fixtures env")
        }
        let fixtures = URL(fileURLWithPath: dir)
        let vad = try SileroVAD()
        let recognizer = try SherpaStreamingRecognizer()
        let store = try SQLiteTranscriptStore.inMemory()
        let session = try await store.startSession(SessionInfo(captureSource: "file", deviceModel: "EarSim"))
        let pipeline = AmbientPipeline(store: store, vad: vad, recognizer: recognizer)
        try await pipeline.run(
            source: FileCaptureSource(url: fixtures.appendingPathComponent("lecture_en_01.wav"), realtime: false),
            sessionID: session)
        let facts = try JSONDecoder().decode(
            [Fact].self, from: Data(contentsOf: fixtures.appendingPathComponent("lecture_en_01.facts.json")))
        var found = 0
        for f in facts {
            let hits = try await store.searchLexical(f.fact, k: 5)
            let words = { (t: String) in Set(t.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)) }
            if hits.contains(where: { h in f.mustContain.contains { m in words(m).isSubset(of: words(h.text)) } }) {
                found += 1
            }
        }
        print("AmbientSmokeTest: \(found)/\(facts.count) planted facts findable")
        XCTAssertGreaterThanOrEqual(Double(found) / Double(facts.count), 0.8)
    }
}
