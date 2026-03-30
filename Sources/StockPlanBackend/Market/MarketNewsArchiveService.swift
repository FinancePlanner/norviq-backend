import Fluent
import Foundation
import StockPlanShared
import Vapor

protocol MarketNewsArchiveService: Sendable {
    func news(symbol: String, limit: Int?, on req: Request) async throws -> [StockNews]
    func archivedNews(symbol: String, limit: Int?, on db: any Database) async throws -> [StockNews]
    func refreshNews(symbol: String, limit: Int?, on req: Request) async throws -> [StockNews]
}

struct MarketNewsArchiveConfig: Sendable {
    let ttlSeconds: Int
    let defaultLimit: Int
    let maxLimit: Int

    static func fromEnvironment() -> MarketNewsArchiveConfig {
        let ttlSeconds = Environment.get("MARKET_TTL_NEWS_SECONDS").flatMap(Int.init(_:)) ?? 900
        let defaultLimit = Environment.get("MARKET_NEWS_DEFAULT_LIMIT").flatMap(Int.init(_:)) ?? 50
        let maxLimit = Environment.get("MARKET_NEWS_MAX_LIMIT").flatMap(Int.init(_:)) ?? 200

        return .init(
            ttlSeconds: max(60, ttlSeconds),
            defaultLimit: max(1, defaultLimit),
            maxLimit: max(1, maxLimit)
        )
    }
}

struct DefaultMarketNewsArchiveService: MarketNewsArchiveService {
    let provider: (any NewsProvider)?
    let config: MarketNewsArchiveConfig

    init(
        provider: (any NewsProvider)?,
        config: MarketNewsArchiveConfig = .fromEnvironment()
    ) {
        self.provider = provider
        self.config = config
    }

    func news(symbol rawSymbol: String, limit rawLimit: Int?, on req: Request) async throws -> [StockNews] {
        let symbol = try normalizeSymbol(rawSymbol)
        let limit = resolveLimit(rawLimit)
        let archived = try await archivedRows(symbol: symbol, limit: limit, on: req.db)

        if isFresh(archived, now: Date()) {
            return archived.compactMap(makeStockNews)
        }

        guard provider != nil else {
            return archived.compactMap(makeStockNews)
        }

        do {
            return try await refreshNews(symbol: symbol, limit: limit, on: req)
        } catch {
            if !archived.isEmpty {
                req.logger.warning("market.news stale fallback symbol=\(symbol)")
                return archived.compactMap(makeStockNews)
            }
            throw mapProviderError(error)
        }
    }

    func archivedNews(symbol rawSymbol: String, limit rawLimit: Int?, on db: any Database) async throws -> [StockNews] {
        let symbol = try normalizeSymbol(rawSymbol)
        let limit = resolveLimit(rawLimit)
        let archived = try await archivedRows(symbol: symbol, limit: limit, on: db)
        return archived.compactMap(makeStockNews)
    }

    func refreshNews(symbol rawSymbol: String, limit rawLimit: Int?, on req: Request) async throws -> [StockNews] {
        guard let provider else {
            throw Abort(
                .notImplemented,
                reason: "News provider not configured. Configure FINNHUB_API_KEY to enable archived market news sync."
            )
        }

        let symbol = try normalizeSymbol(rawSymbol)
        let limit = resolveLimit(rawLimit)
        let fetchedAt = Date()
        let articles = try await provider.fetch(symbols: [symbol], on: req)

        for article in articles {
            guard let normalized = try normalize(article, expectedSymbol: symbol, provider: provider.name) else {
                continue
            }
            try await upsert(normalized, fetchedAt: fetchedAt, on: req.db)
        }

        let archived = try await archivedRows(symbol: symbol, limit: limit, on: req.db)
        return archived.compactMap(makeStockNews)
    }
}

private extension DefaultMarketNewsArchiveService {
    struct NormalizedArchiveArticle: Sendable {
        let provider: String
        let symbol: String
        let headline: String
        let source: String?
        let url: String
        let summary: String?
        let publishedAt: Date
    }

    func normalize(
        _ raw: ProviderNewsItem,
        expectedSymbol: String,
        provider: String
    ) throws -> NormalizedArchiveArticle? {
        let symbol = try normalizeSymbol(raw.symbol)
        guard symbol == expectedSymbol else {
            return nil
        }

        let headline = raw.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headline.isEmpty else {
            return nil
        }

        guard let url = try normalizeURL(raw.url) else {
            return nil
        }

        return NormalizedArchiveArticle(
            provider: provider,
            symbol: symbol,
            headline: headline,
            source: trimToNil(raw.source),
            url: url,
            summary: trimToNil(raw.summary),
            publishedAt: raw.publishedAt
        )
    }

    func upsert(
        _ article: NormalizedArchiveArticle,
        fetchedAt: Date,
        on db: any Database
    ) async throws {
        if let existing = try await findDuplicate(for: article, on: db) {
            existing.headline = article.headline
            existing.source = article.source
            existing.url = article.url
            existing.summary = article.summary
            existing.publishedAt = article.publishedAt
            existing.fetchedAt = fetchedAt
            try await existing.save(on: db)
            return
        }

        let row = MarketNewsArchive(
            provider: article.provider,
            symbol: article.symbol,
            headline: article.headline,
            source: article.source,
            url: article.url,
            summary: article.summary,
            publishedAt: article.publishedAt,
            fetchedAt: fetchedAt
        )
        try await row.save(on: db)
    }

    func findDuplicate(
        for article: NormalizedArchiveArticle,
        on db: any Database
    ) async throws -> MarketNewsArchive? {
        if let existing = try await MarketNewsArchive.query(on: db)
            .filter(\.$provider == article.provider)
            .filter(\.$symbol == article.symbol)
            .filter(\.$url == article.url)
            .first()
        {
            return existing
        }

        let candidates = try await MarketNewsArchive.query(on: db)
            .filter(\.$provider == article.provider)
            .filter(\.$symbol == article.symbol)
            .filter(\.$headline == article.headline)
            .sort(\.$publishedAt, .descending)
            .limit(10)
            .all()

        return candidates.first { candidate in
            abs(candidate.publishedAt.timeIntervalSince(article.publishedAt)) < 1
        }
    }

    func archivedRows(
        symbol: String,
        limit: Int,
        on db: any Database
    ) async throws -> [MarketNewsArchive] {
        try await MarketNewsArchive.query(on: db)
            .filter(\.$symbol == symbol)
            .sort(\.$publishedAt, .descending)
            .sort(\.$updatedAt, .descending)
            .limit(limit)
            .all()
    }

    func makeStockNews(from row: MarketNewsArchive) -> StockNews? {
        guard let url = trimToNil(row.url) else {
            return nil
        }

        return StockNews(
            title: row.headline,
            url: url,
            date: formatISODateTime(row.publishedAt)
        )
    }

    func resolveLimit(_ rawLimit: Int?) -> Int {
        min(max(rawLimit ?? config.defaultLimit, 1), config.maxLimit)
    }

    func normalizeSymbol(_ raw: String) throws -> String {
        let symbol = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !symbol.isEmpty else {
            throw Abort(.badRequest, reason: "Symbol is required.")
        }
        return symbol
    }

    func normalizeURL(_ raw: String?) throws -> String? {
        guard let value = trimToNil(raw) else {
            return nil
        }

        guard
            let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            url.host != nil
        else {
            throw Abort(.badRequest, reason: "Invalid provider news URL.")
        }

        return value
    }

    func trimToNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func formatISODateTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func isFresh(_ rows: [MarketNewsArchive], now: Date) -> Bool {
        guard let lastFetchedAt = rows.map(\.fetchedAt).max() else {
            return false
        }

        return now.timeIntervalSince(lastFetchedAt) <= TimeInterval(config.ttlSeconds)
    }

    func mapProviderError(_ error: any Error) -> any Error {
        if let abort = error as? any AbortError,
           abort.status == .notFound || abort.status == .badRequest || abort.status == .notImplemented
        {
            return abort
        }

        return Abort(
            .serviceUnavailable,
            reason: "Market news provider unavailable. Check FINNHUB_API_KEY and upstream provider health."
        )
    }
}
