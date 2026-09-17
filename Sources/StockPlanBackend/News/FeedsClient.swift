import Foundation
import Vapor

// MARK: - JSON Feed 1.1 wire types (server-internal; the shared package never sees these)

/// A JSON Feed 1.1 document as served by the cluster's shared feed aggregator,
/// including its `_feeds` extension. Only headline fields are modelled; the
/// aggregator never sends bodies and we would not keep them if it did.
struct JSONFeedDocument: Decodable, Sendable {
    let title: String
    let homePageUrl: String?
    let feedUrl: String?
    let items: [JSONFeedItem]
    let feeds: JSONFeedExtension?

    enum CodingKeys: String, CodingKey {
        case title
        case homePageUrl = "home_page_url"
        case feedUrl = "feed_url"
        case items
        case feeds = "_feeds"
    }

    static func decode(from data: Data) throws -> JSONFeedDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = JSONFeedDates.parse(raw) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unparseable date \(raw)"))
        }
        return try decoder.decode(JSONFeedDocument.self, from: data)
    }
}

struct JSONFeedItem: Decodable, Sendable {
    let id: String
    let url: String?
    let title: String
    let datePublished: Date
    let image: String?
    let feeds: JSONFeedItemExtension

    enum CodingKeys: String, CodingKey {
        case id, url, title, image
        case datePublished = "date_published"
        case feeds = "_feeds"
    }
}

struct JSONFeedItemExtension: Decodable, Sendable {
    let sourceName: String
    let sourceUrl: String?
    let feedUrl: String
    let dateEstimated: Bool?

    enum CodingKeys: String, CodingKey {
        case sourceName = "source_name"
        case sourceUrl = "source_url"
        case feedUrl = "feed_url"
        case dateEstimated = "date_estimated"
    }
}

struct JSONFeedExtension: Decodable, Sendable {
    let warming: [String]
    let stale: [String]
    let generatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case warming, stale
        case generatedAt = "generated_at"
    }
}

/// One feed the aggregator found behind a site URL.
struct FeedCandidate: Decodable, Sendable, Equatable {
    let url: String
    let type: String
    let title: String
}

enum JSONFeedDates {
    /// Formatters are built per call: ISO8601DateFormatter is not Sendable and
    /// the cost is negligible next to the HTTP round trip that precedes it.
    static func parse(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

// MARK: - Client

/// Talks to the shared feed aggregator. Named for the wire format it consumes,
/// not for the service, so pointing it at any JSON Feed source is configuration.
protocol FeedsClient: Sendable {
    /// Merged newest-first timeline across `feeds`. Never blocks on upstream
    /// publishers; feeds not yet fetched come back in `_feeds.warming`.
    func items(feeds: [String], limit: Int, on req: Request) async throws -> JSONFeedDocument
    /// Feed candidates behind a site or feed URL. Empty means the site has none.
    func discover(url: String, on req: Request) async throws -> [FeedCandidate]
}

struct HTTPFeedsClient: FeedsClient {
    let baseURL: String

    /// The aggregator caps one call at 25 feeds.
    static let maxFeedsPerCall = 25

    func items(feeds: [String], limit: Int, on req: Request) async throws -> JSONFeedDocument {
        guard !feeds.isEmpty else {
            return JSONFeedDocument(title: "", homePageUrl: nil, feedUrl: nil, items: [], feeds: nil)
        }
        var components = URLComponents(string: trimmedBase + "/v1/items")
        components?.queryItems = [
            URLQueryItem(name: "feeds", value: feeds.prefix(Self.maxFeedsPerCall).joined(separator: ",")),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components?.url else {
            throw Abort(.internalServerError, reason: "Invalid FEEDS_BASE_URL configuration.")
        }
        let response = try await req.client.get(URI(string: url.absoluteString)) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/feed+json, application/json")
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "Feed aggregator returned \(response.status.code) for /v1/items: \(bodyText(response))")
        }
        return try JSONFeedDocument.decode(from: bodyData(response))
    }

    func discover(url: String, on req: Request) async throws -> [FeedCandidate] {
        struct Body: Content {
            let url: String
        }
        struct Reply: Decodable {
            let candidates: [FeedCandidate]
        }
        let response = try await req.client.post(URI(string: trimmedBase + "/v1/discover")) { clientRequest in
            try clientRequest.content.encode(Body(url: url), as: .json)
        }
        switch response.status {
        case .ok:
            return try JSONDecoder().decode(Reply.self, from: bodyData(response)).candidates
        case .badRequest:
            throw Abort(.badRequest, reason: "That URL cannot be used as a feed: \(bodyText(response))")
        default:
            throw Abort(.badGateway, reason: "Feed discovery failed with status \(response.status.code): \(bodyText(response))")
        }
    }

    private var trimmedBase: String {
        baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    }

    private func bodyData(_ response: ClientResponse) -> Data {
        guard let buffer = response.body else {
            return Data()
        }
        return Data(buffer.readableBytesView)
    }

    private func bodyText(_ response: ClientResponse) -> String {
        (String(bytes: bodyData(response).prefix(300), encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
