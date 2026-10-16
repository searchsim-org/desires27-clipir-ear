import Foundation

/// One search hit: what the answerer sees and the domain the spoken answer names (ADR-021).
public struct WebResult: Sendable, Equatable {
    public let title: String
    public let url: URL
    public let snippet: String
    public var domain: String {
        let h = url.host() ?? ""
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    public init(title: String, url: URL, snippet: String) {
        (self.title, self.url, self.snippet) = (title, url, snippet)
    }
}

public protocol WebSearching: Sendable {
    func search(_ query: String) async throws -> [WebResult]
}

/// Brave Search Web Search API from the phone (ADR-021). Sends the query text and nothing else; the host is
/// reachable only while EgressGuard has web search switched on. Results live in memory for one answer.
public struct BraveSearch: WebSearching {
    public static let host = "api.search.brave.com"
    let key: @Sendable () -> String?
    let egress: EgressGuard
    let configuration: URLSessionConfiguration

    public init(
        key: @escaping @Sendable () -> String?, egress: EgressGuard = .shared,
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        (self.key, self.egress, self.configuration) = (key, egress, configuration)
    }

    struct Response: Decodable {
        struct Web: Decodable { let results: [Item] }
        struct Item: Decodable { let title: String, url: String, description: String? }
        let web: Web?
    }

    public func search(_ query: String) async throws -> [WebResult] {
        guard let key = key(), !key.isEmpty else {
            throw EarError.model("Add your Brave Search key in Settings first.")
        }
        var c = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: "3")]
        var req = URLRequest(url: c.url!, timeoutInterval: 8)
        req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = try egress.session(for: req.url!, configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw EarError.model("Brave refused the key. Check it in Settings.") }
        guard status == 200 else { throw EarError.model("The search service answered \(status).") }
        let items = try JSONDecoder().decode(Response.self, from: data).web?.results ?? []
        return items.prefix(3).compactMap { i in
            URL(string: i.url).map { WebResult(title: i.title, url: $0, snippet: Self.plain(i.description ?? "")) }
        }
    }

    /// Brave marks matches with <strong>; the answerer gets plain text.
    static func plain(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
