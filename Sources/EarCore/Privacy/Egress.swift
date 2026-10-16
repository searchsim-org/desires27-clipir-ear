import CryptoKit
import Foundation
import Synchronization

/// Every destination the app talked to, or tried to (§2.5). Debug screen and harness read it.
public final class ConnectionLedger: Sendable {
    public struct Entry: Sendable, Codable, Equatable {
        public let at: Date
        public let host: String
        public let allowed: Bool
    }
    public static let shared = ConnectionLedger()
    private let entries = Mutex<[Entry]>([])

    public func record(host: String, allowed: Bool) {
        entries.withLock { $0.append(Entry(at: Date(), host: host, allowed: allowed)) }
    }
    public func all() -> [Entry] { entries.withLock { $0 } }
    public func violations() -> [Entry] { all().filter { !$0.allowed } }
    public func reset() { entries.withLock { $0 = [] } }
}

/// The only way to open a network session (§2.5). Allowed: localhost, the paired Mac, the model hosts
/// only while a user-started download runs, and the web-search host while the user has web search on (ADR-021). Redirects are checked hop by hop and recorded in the ledger.
public final class EgressGuard: Sendable {
    public static let shared = EgressGuard()
    private static let local: Set<String> = ["localhost", "127.0.0.1", "::1"]
    private let state = Mutex<(mac: String?, modelHosts: [String], webSearch: Bool)>((nil, [], false))
    private let ledger: ConnectionLedger

    public init(ledger: ConnectionLedger = .shared) { self.ledger = ledger }

    public func setPairedMac(host: String?) { state.withLock { $0.mac = host?.lowercased() } }

    /// Settings → Web search (ADR-021, default off).
    public func setWebSearch(enabled: Bool) { state.withLock { $0.webSearch = enabled } }

    /// Opens the model-download window for the duration of `body` (explicit user action only).
    public func withModelDownloads<T>(hosts: [String], _ body: () async throws -> T) async rethrows -> T {
        state.withLock { $0.modelHosts = hosts.map { $0.lowercased() } }
        defer { state.withLock { $0.modelHosts = [] } }
        return try await body()
    }

    public func isAllowed(host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if Self.local.contains(h) { return true }
        return state.withLock { s in
            if h == s.mac { return true }
            if s.webSearch, h == BraveSearch.host { return true }
            return s.modelHosts.contains { h == $0 || h.hasSuffix("." + $0) }
        }
    }

    /// Records and checks one destination; throws if it is not allowed.
    public func check(host: String) throws {
        let ok = isAllowed(host: host)
        ledger.record(host: host, allowed: ok)
        if !ok { throw EarError.egressBlocked(host: host) }
    }

    /// A URLSession for `url` whose redirects are also guarded. With `pin` (lower-case hex SHA-256 of the DER
    /// certificate, P8.4) the server must present exactly that certificate; CA trust is not consulted.
    public func session(for url: URL, configuration: URLSessionConfiguration = .ephemeral, pin: String? = nil) throws
        -> URLSession
    {
        try check(host: url.host() ?? "")
        return URLSession(
            configuration: configuration, delegate: RedirectGuard(guard: self, pin: pin?.lowercased()),
            delegateQueue: nil)
    }
}

final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let egress: EgressGuard
    let pin: String?
    init(guard egress: EgressGuard, pin: String? = nil) { (self.egress, self.pin) = (egress, pin) }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust, let pin
        else { return (.performDefaultHandling, nil) }
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
            Self.sha256(SecCertificateCopyData(leaf) as Data) == pin
        else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let host = request.url?.host(), (try? egress.check(host: host)) != nil else { return nil }
        return request
    }
}
