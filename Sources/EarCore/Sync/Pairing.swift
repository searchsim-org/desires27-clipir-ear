import Foundation
import Network
import Security

/// What `earbridge pair` shows: QR JSON {"host","port","token","fp"} or the 8-character code typed with a host (P5.5).
public struct PairingInfo: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var token: String
    public var fp: String
    public var name: String?

    public init(host: String, port: Int = 9478, token: String, fp: String = "none", name: String? = nil) {
        (self.host, self.port, self.token, self.fp, self.name) = (host, port, token, fp, name)
    }

    public static func fromQR(_ text: String) -> PairingInfo? {
        try? JSONDecoder().decode(PairingInfo.self, from: Data(text.utf8))
    }

    /// Manual entry: host (optionally host:port) + the 8-character code.
    public static func manual(host: String, code: String) -> PairingInfo? {
        let code = code.uppercased().filter { !$0.isWhitespace }
        let parts = host.split(separator: ":")
        guard code.count == 8, let h = parts.first, !h.isEmpty else { return nil }
        return PairingInfo(host: String(h), port: parts.count > 1 ? Int(parts[1]) ?? 9478 : 9478, token: code)
    }

    /// TLS with a pinned certificate when the QR carried a fingerprint (P8.4); plain ws:// only for fp "none".
    public var url: URL { URL(string: "\(fp == "none" ? "ws" : "wss")://\(host):\(port)/ear/v1")! }
}

/// Paired Mac in the keychain (never in UserDefaults or exports).
public enum PairingStore {
    static let service = "de.zerhoudi.clipir-ear.bridge"

    public static func save(_ p: PairingInfo) throws {
        forget()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "paired-mac", kSecValueData as String: try JSONEncoder().encode(p),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw EarError.notFound("keychain error \(status)") }
    }

    public static func load() -> PairingInfo? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "paired-mac", kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(PairingInfo.self, from: d)
    }

    public static func forget() {
        SecItemDelete(
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

/// Finds `_clipir-ear._tcp` services on the LAN (P5.5). Results are service names; connecting resolves them.
public final class BonjourBrowser: @unchecked Sendable {
    private let browser = NWBrowser(for: .bonjour(type: "_clipir-ear._tcp", domain: nil), using: .tcp)
    public let found: AsyncStream<[String]>
    private let continuation: AsyncStream<[String]>.Continuation

    public init() {
        (found, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        browser.browseResultsChangedHandler = { [continuation] results, _ in
            continuation.yield(
                results.compactMap { r in
                    if case .service(let name, _, _, _) = r.endpoint { return name }
                    return nil
                })
        }
    }

    public func start() { browser.start(queue: .global(qos: .utility)) }
    public func stop() {
        browser.cancel()
        continuation.finish()
    }
}
