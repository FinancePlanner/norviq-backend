import Vapor
import Foundation

struct ProviderNewsItem: Sendable {
    let symbol: String
    let headline: String
    let source: String?
    let url: String?
    let summary: String?
    let publishedAt: Date
}

protocol NewsProvider: Sendable {
    var name: String { get }
    func fetch(symbols: [String], on req: Request) async throws -> [ProviderNewsItem]
}

struct ExternalAPINewsProvider: NewsProvider {
    let name: String = "external_api"

    func fetch(symbols: [String], on req: Request) async throws -> [ProviderNewsItem] {
        throw Abort(.notImplemented, reason: "External API news provider fetch is not implemented yet.")
    }
}

struct RSSNewsProvider: NewsProvider {
    let name: String = "rss"

    func fetch(symbols: [String], on req: Request) async throws -> [ProviderNewsItem] {
        throw Abort(.notImplemented, reason: "RSS news provider fetch is not implemented yet.")
    }
}
