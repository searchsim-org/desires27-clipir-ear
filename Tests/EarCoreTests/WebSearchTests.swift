import Foundation
import XCTest

@testable import EarCore

/// Stands in for api.search.brave.com: records the request, answers with a canned Brave response.
final class BraveStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    static let body = #"""
        {"web": {"results": [
          {"title": "Adam optimizer", "url": "https://www.example.org/adam",
           "description": "<strong>Adam</strong> adapts the learning rate per parameter."},
          {"title": "Second", "url": "https://docs.example.com/b", "description": "Second result."}
        ]}}
        """#

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class WebSearchTests: XCTestCase {
    private func stubbed() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [BraveStub.self]
        return c
    }

    func testBraveSendsOnlyTheQueryWithTheKeyAndParsesResults() async throws {
        let egress = EgressGuard(ledger: ConnectionLedger())
        egress.setWebSearch(enabled: true)
        let brave = BraveSearch(key: { "KEY123" }, egress: egress, configuration: stubbed())
        let results = try await brave.search("what is the adam optimizer")
        let req = try XCTUnwrap(BraveStub.lastRequest)
        XCTAssertEqual(req.url?.host(), "api.search.brave.com")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Subscription-Token"), "KEY123")
        let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(Set(items.map(\.name)), ["q", "count"])
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "what is the adam optimizer")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].domain, "example.org")
        XCTAssertEqual(results[0].snippet, "Adam adapts the learning rate per parameter.")
    }

    func testSearchIsBlockedWhileTheSettingIsOff() async {
        let egress = EgressGuard(ledger: ConnectionLedger())
        let brave = BraveSearch(key: { "KEY123" }, egress: egress, configuration: stubbed())
        do {
            _ = try await brave.search("anything")
            XCTFail("searched with web search off")
        } catch EarError.egressBlocked(let host) {
            XCTAssertEqual(host, "api.search.brave.com")
        } catch { XCTFail("\(error)") }
    }

    func testMissingKeyAsksTheUserToAddItInSettings() async {
        let egress = EgressGuard(ledger: ConnectionLedger())
        egress.setWebSearch(enabled: true)
        let brave = BraveSearch(key: { nil }, egress: egress, configuration: stubbed())
        do {
            _ = try await brave.search("anything")
            XCTFail("searched without a key")
        } catch { XCTAssertTrue("\(error)".contains("Settings"), "\(error)") }
    }

    func testApprovedSearchSpeaksASourcedAnswerFromTheResults() async throws {
        struct Fake: WebSearching {
            func search(_ q: String) async throws -> [WebResult] {
                [
                    WebResult(
                        title: "Adam", url: URL(string: "https://www.example.org/adam")!, snippet: "Adam adapts rates.")
                ]
            }
        }
        let seen = Box<[String]>([])
        let answerer = MockAnswerer { req in
            seen.value = req.notes
            return "It adapts the learning rate per parameter.\nSOURCE: notes"
        }
        let exec = EarActionExecutor(
            store: try SQLiteTranscriptStore.inMemory(), search: Fake(), answerer: answerer)
        let spoken = try await exec.execute(.webSearch(query: "adam optimizer"))
        XCTAssertEqual(spoken, "According to example.org, it adapts the learning rate per parameter.")
        XCTAssertEqual(seen.value.count, 1)
        XCTAssertTrue(seen.value[0].contains("Adam adapts rates."))
    }

    func testWithoutSearchTheExecutorPointsToSettings() async throws {
        let exec = EarActionExecutor(store: try SQLiteTranscriptStore.inMemory())
        let spoken = try await exec.execute(.webSearch(query: "x"))
        XCTAssertTrue(spoken.contains("Settings"), spoken)
    }
}

final class WebSearchFlowTests: XCTestCase {
    struct Answering: ActionExecutor {
        func execute(_ a: EarAction) async throws -> String { "According to example.org, it adapts rates." }
    }

    /// ADR-021: with web search on, a search runs at once; no spoken "yes" first.
    func testSearchRunsWithoutAskingForConfirmation() async throws {
        let store = try SQLiteTranscriptStore.inMemory()
        _ = try await store.startSession(SessionInfo(captureSource: "t"))
        let p = EarPipeline(
            config: PipelineConfig(),
            deps: PipelineDeps(
                store: store, makeSource: { throw EarError.cancelled },
                makeVAD: { EnergyVAD() }, makeRecognizer: { ScriptedRecognizer(lines: []) },
                answerer: MockAnswerer(), executor: Answering()))
        let h = try await p.ask(question: "search the web for the adam optimizer")
        var spoken: [String] = []
        for await e in h.events { if case .sentence(let s) = e { spoken.append(s) } }
        XCTAssertEqual(spoken, ["According to example.org, it adapts rates."])
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}
