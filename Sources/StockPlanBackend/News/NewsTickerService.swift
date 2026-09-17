import Fluent
import Foundation
import StockPlanShared
import Vapor

protocol NewsTickerServicing: Sendable {
    func ticker(userId: UUID, limit: Int, on req: Request) async throws -> NewsTickerResponse
    func settings(userId: UUID, on db: any Database) async throws -> NewsTickerSettings
    func updateSettings(userId: UUID, enabled: Bool, on db: any Database) async throws -> NewsTickerSettings
    func listFeeds(userId: UUID, on db: any Database) async throws -> NewsTickerFeedsResponse
    func addFeed(userId: UUID, url: String, on req: Request) async throws -> NewsTickerFeed
    func removeFeed(userId: UUID, feedId: UUID, on db: any Database) async throws
}

/// Serves the breaking-news ticker from the shared feed aggregator: curated
/// market feeds plus whatever the user added, one aggregator call, cached for
/// a minute per distinct feed set so a dashboard refresh storm costs nothing.
struct DefaultNewsTickerService: NewsTickerServicing {
    let client: any FeedsClient
    let curatedFeeds: [String]
    let maxUserFeeds: Int
    let cache: NewsTickerCache

    init(client: any FeedsClient, curatedFeeds: [String], maxUserFeeds: Int = 10, cacheTTL: TimeInterval = 60) {
        self.client = client
        self.curatedFeeds = curatedFeeds
        self.maxUserFeeds = maxUserFeeds
        cache = NewsTickerCache(ttl: cacheTTL)
    }

    func ticker(userId: UUID, limit: Int, on req: Request) async throws -> NewsTickerResponse {
        let now = Date()
        guard try await settings(userId: userId, on: req.db).enabled else {
            return NewsTickerResponse(enabled: false, items: [], generatedAt: NewsTickerMapping.iso(now), stale: false)
        }
        let userFeeds = try await NewsTickerFeedSubscription.query(on: req.db)
            .filter(\.$userId == userId)
            .sort(\.$createdAt)
            .all()
            .map(\.feedUrl)
        let feeds = NewsTickerMapping.feedList(curated: curatedFeeds, user: userFeeds)
        guard !feeds.isEmpty else {
            return NewsTickerResponse(enabled: true, items: [], generatedAt: NewsTickerMapping.iso(now), stale: false)
        }
        let key = feeds.joined(separator: "\n") + "|\(limit)"
        if let cached = await cache.get(key, now: now) {
            return cached
        }
        let doc = try await client.items(feeds: feeds, limit: limit, on: req)
        let response = NewsTickerMapping.response(from: doc, enabled: true, now: now)
        await cache.set(key, response, now: now)
        return response
    }

    func settings(userId: UUID, on db: any Database) async throws -> NewsTickerSettings {
        let pref = try await NewsTickerPreference.query(on: db).filter(\.$userId == userId).first()
        return NewsTickerSettings(enabled: pref?.enabled ?? true)
    }

    func updateSettings(userId: UUID, enabled: Bool, on db: any Database) async throws -> NewsTickerSettings {
        if let existing = try await NewsTickerPreference.query(on: db).filter(\.$userId == userId).first() {
            existing.enabled = enabled
            try await existing.save(on: db)
        } else {
            try await NewsTickerPreference(userId: userId, enabled: enabled).save(on: db)
        }
        return NewsTickerSettings(enabled: enabled)
    }

    func listFeeds(userId: UUID, on db: any Database) async throws -> NewsTickerFeedsResponse {
        let rows = try await NewsTickerFeedSubscription.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$createdAt)
            .all()
        return try NewsTickerFeedsResponse(feeds: rows.map(NewsTickerMapping.feed), maxFeeds: maxUserFeeds)
    }

    func addFeed(userId: UUID, url rawURL: String, on req: Request) async throws -> NewsTickerFeed {
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme), parsed.host != nil else {
            throw Abort(.badRequest, reason: "Enter a full http(s) URL.")
        }
        let count = try await NewsTickerFeedSubscription.query(on: req.db).filter(\.$userId == userId).count()
        guard count < maxUserFeeds else {
            throw Abort(.conflict, reason: "You can follow at most \(maxUserFeeds) feeds.")
        }
        let candidates = try await client.discover(url: url, on: req)
        guard let chosen = candidates.first else {
            throw Abort(.unprocessableEntity, reason: "No feed found at that address.")
        }
        let duplicate = try await NewsTickerFeedSubscription.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$feedUrl == chosen.url)
            .first()
        guard duplicate == nil else {
            throw Abort(.conflict, reason: "You already follow that feed.")
        }
        let row = NewsTickerFeedSubscription(userId: userId, feedUrl: chosen.url, title: chosen.title.isEmpty ? nil : chosen.title)
        try await row.save(on: req.db)
        return try NewsTickerMapping.feed(row)
    }

    func removeFeed(userId: UUID, feedId: UUID, on db: any Database) async throws {
        guard let row = try await NewsTickerFeedSubscription.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$id == feedId)
            .first()
        else {
            throw Abort(.notFound, reason: "Feed not found.")
        }
        try await row.delete(on: db)
    }
}

/// Pure mapping helpers, tested without a database.
enum NewsTickerMapping {
    static func response(from doc: JSONFeedDocument, enabled: Bool, now: Date) -> NewsTickerResponse {
        let items = doc.items.map { item in
            NewsTickerItem(
                id: item.id,
                title: item.title,
                url: item.url,
                source: item.feeds.sourceName,
                sourceUrl: item.feeds.sourceUrl,
                publishedAt: iso(item.datePublished)
            )
        }
        return NewsTickerResponse(
            enabled: enabled,
            items: items,
            generatedAt: iso(doc.feeds?.generatedAt ?? now),
            stale: !(doc.feeds?.stale.isEmpty ?? true)
        )
    }

    /// Curated first, then the user's, deduped, capped at what one aggregator
    /// call accepts.
    static func feedList(curated: [String], user: [String]) -> [String] {
        var seen = Set<String>()
        return (curated + user)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(HTTPFeedsClient.maxFeedsPerCall)
            .map(\.self)
    }

    static func feed(_ row: NewsTickerFeedSubscription) throws -> NewsTickerFeed {
        try NewsTickerFeed(id: row.requireID().uuidString, url: row.feedUrl, title: row.title)
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

/// Tiny TTL cache keyed by feed set. Bounded so a stream of one-off feed sets
/// cannot grow it without limit.
private struct NewsTickerCacheEntry {
    let response: NewsTickerResponse
    let expires: Date
}

actor NewsTickerCache {
    private let ttl: TimeInterval
    private var entries: [String: NewsTickerCacheEntry] = [:]
    private let maxEntries = 256

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func get(_ key: String, now: Date) -> NewsTickerResponse? {
        guard let entry = entries[key], entry.expires > now else {
            return nil
        }
        return entry.response
    }

    func set(_ key: String, _ response: NewsTickerResponse, now: Date) {
        if entries.count >= maxEntries {
            entries = entries.filter { $0.value.expires > now }
            if entries.count >= maxEntries {
                entries.removeAll()
            }
        }
        entries[key] = NewsTickerCacheEntry(response: response, expires: now.addingTimeInterval(ttl))
    }
}

extension Application {
    private struct NewsTickerServiceKey: StorageKey {
        typealias Value = any NewsTickerServicing
    }

    var newsTickerService: any NewsTickerServicing {
        get {
            guard let service = storage[NewsTickerServiceKey.self] else {
                fatalError("NewsTickerServicing not configured")
            }
            return service
        }
        set {
            storage[NewsTickerServiceKey.self] = newValue
        }
    }
}

extension Request {
    var newsTickerService: any NewsTickerServicing {
        application.newsTickerService
    }
}

/// Stands in when FEEDS_BASE_URL is unset: the ticker reports itself disabled
/// and the settings endpoints still work, so clients need no special case.
struct DisabledNewsTickerService: NewsTickerServicing {
    func ticker(userId _: UUID, limit _: Int, on _: Request) async throws -> NewsTickerResponse {
        NewsTickerResponse(enabled: false, items: [], generatedAt: NewsTickerMapping.iso(Date()), stale: false)
    }

    func settings(userId _: UUID, on _: any Database) async throws -> NewsTickerSettings {
        NewsTickerSettings(enabled: false)
    }

    func updateSettings(userId _: UUID, enabled _: Bool, on _: any Database) async throws -> NewsTickerSettings {
        throw Abort(.serviceUnavailable, reason: "The news ticker is not configured on this server.")
    }

    func listFeeds(userId _: UUID, on _: any Database) async throws -> NewsTickerFeedsResponse {
        NewsTickerFeedsResponse(feeds: [], maxFeeds: 0)
    }

    func addFeed(userId _: UUID, url _: String, on _: Request) async throws -> NewsTickerFeed {
        throw Abort(.serviceUnavailable, reason: "The news ticker is not configured on this server.")
    }

    func removeFeed(userId _: UUID, feedId _: UUID, on _: any Database) async throws {
        throw Abort(.serviceUnavailable, reason: "The news ticker is not configured on this server.")
    }
}
