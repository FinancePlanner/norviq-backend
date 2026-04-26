import Fluent
import Foundation
import Vapor

enum NewsServiceError: Error {
    case notFound
    case invalidSymbol
    case invalidHeadline
    case invalidURL
    case invalidPublishedAt
}

extension NewsServiceError: AbortError {
    var status: HTTPResponseStatus {
        switch self {
        case .notFound:
            .notFound
        case .invalidSymbol, .invalidHeadline, .invalidURL, .invalidPublishedAt:
            .badRequest
        }
    }

    var reason: String {
        switch self {
        case .notFound:
            "News item not found."
        case .invalidSymbol:
            "Invalid symbol."
        case .invalidHeadline:
            "Invalid headline."
        case .invalidURL:
            "Invalid url."
        case .invalidPublishedAt:
            "Invalid publishedAt. Expected ISO8601 datetime."
        }
    }
}

protocol NewsService: Sendable {
    func list(userId: UUID, symbol: String?, limit: Int, cursor: Date?, on db: any Database) async throws -> (items: [NewsItemResponse], nextCursor: String?)
    func feed(userId: UUID, limit: Int?, on db: any Database) async throws -> [NewsItemResponse]
    func get(id: UUID, userId: UUID, on db: any Database) async throws -> NewsItemResponse
    func create(payload: NewsItemRequest, userId: UUID, on db: any Database) async throws -> NewsItemResponse
    func update(id: UUID, payload: NewsItemRequest, userId: UUID, on db: any Database) async throws -> NewsItemResponse
    func delete(id: UUID, userId: UUID, on db: any Database) async throws
    func syncNews(userId: UUID, on req: Request) async throws -> NewsSyncResponse
    func ingestFinnhubWebhook(payload: FinnhubNewsWebhookRequest, on db: any Database) async throws -> FinnhubNewsWebhookResponse
}

struct DefaultNewsService: NewsService {
    let repo: any NewsRepository
    let provider: (any NewsProvider)?

    init(repo: any NewsRepository = DatabaseNewsRepository(), provider: (any NewsProvider)? = nil) {
        self.repo = repo
        self.provider = provider
    }

    func list(userId: UUID, symbol: String?, limit: Int, cursor: Date?, on db: any Database) async throws -> (items: [NewsItemResponse], nextCursor: String?) {
        let normalized = normalizedSymbolValue(symbol)
        let maxLimit = 200
        let fetchLimit = limit + 1
        let newsItems = try await repo.list(userId: userId, symbol: normalized, limit: fetchLimit, cursor: cursor, on: db)
        if newsItems.count > limit, limit < maxLimit {
            let pageItems = Array(newsItems.prefix(limit))
            let items = try pageItems.map(makeResponse)
            guard let last = pageItems.last else {
                return (items, nil)
            }
            let nextCursor = formatISODateTime(last.publishedAt)
            return (items, nextCursor)
        } else {
            let items = try Array(newsItems.prefix(limit)).map(makeResponse)
            return (items, nil)
        }
    }

    func list(userId: UUID, symbol: String?, on db: any Database) async throws -> [NewsItemResponse] {
        let result = try await list(userId: userId, symbol: symbol, limit: 100, cursor: nil, on: db)
        return result.items
    }

    func feed(userId: UUID, limit: Int?, on db: any Database) async throws -> [NewsItemResponse] {
        let clampedLimit = max(1, min(limit ?? 50, 100))
        let tracked = try await repo.trackedSymbols(userId: userId, on: db)
            .compactMap { normalizedSymbolValue($0) }
        let items = try await repo.listFeed(userId: userId, trackedSymbols: tracked, limit: clampedLimit, on: db)
        return try items.map(makeResponse)
    }

    func get(id: UUID, userId: UUID, on db: any Database) async throws -> NewsItemResponse {
        guard let item = try await repo.find(id: id, userId: userId, on: db)
        else {
            throw NewsServiceError.notFound
        }
        return try makeResponse(from: item)
    }

    func create(payload: NewsItemRequest, userId: UUID, on db: any Database) async throws -> NewsItemResponse {
        let model = try NewsItem(
            userId: userId,
            symbol: normalizeSymbol(payload.symbol),
            headline: normalizeHeadline(payload.headline),
            source: trimToNil(payload.source),
            url: normalizeURL(payload.url),
            summary: trimToNil(payload.summary),
            publishedAt: parsePublishedAt(payload.publishedAt)
        )

        try await repo.save(model, on: db)
        return try makeResponse(from: model)
    }

    func update(id: UUID, payload: NewsItemRequest, userId: UUID, on db: any Database) async throws -> NewsItemResponse {
        guard let model = try await repo.find(id: id, userId: userId, on: db)
        else {
            throw NewsServiceError.notFound
        }

        model.symbol = try normalizeSymbol(payload.symbol)
        model.headline = try normalizeHeadline(payload.headline)
        model.source = trimToNil(payload.source)
        model.url = try normalizeURL(payload.url)
        model.summary = trimToNil(payload.summary)
        model.publishedAt = try parsePublishedAt(payload.publishedAt)

        try await repo.save(model, on: db)
        return try makeResponse(from: model)
    }

    func delete(id: UUID, userId: UUID, on db: any Database) async throws {
        guard let model = try await repo.find(id: id, userId: userId, on: db)
        else {
            throw NewsServiceError.notFound
        }
        try await repo.delete(model, on: db)
    }

    func syncNews(userId: UUID, on req: Request) async throws -> NewsSyncResponse {
        guard let provider else {
            throw Abort(
                .notImplemented,
                reason: "News provider not configured. Configure FINNHUB_API_KEY to enable Finnhub sync."
            )
        }

        let symbols = try await repo.trackedSymbols(userId: userId, on: req.db)
            .compactMap { normalizedSymbolValue($0) }
        let trackedSymbols = Set(symbols)
        let fetched = try await provider.fetch(symbols: symbols, on: req)
        let normalizedArticles = try fetched.compactMap(normalizeProviderArticle)

        var insertedCount = 0
        var updatedCount = 0
        var skippedCount = max(fetched.count - normalizedArticles.count, 0)

        for article in normalizedArticles {
            guard article.symbols.count == 1, let symbol = article.symbols.first, trackedSymbols.contains(symbol) else {
                skippedCount += 1
                continue
            }

            let upsertResult = try await upsertNewsItem(
                userId: userId,
                symbol: symbol,
                article: article,
                on: req.db
            )
            switch upsertResult {
            case .inserted:
                insertedCount += 1
            case .updated:
                updatedCount += 1
            case .skipped:
                skippedCount += 1
            }
        }

        return NewsSyncResponse(
            provider: provider.name,
            symbolsCount: symbols.count,
            fetchedCount: fetched.count,
            insertedCount: insertedCount,
            updatedCount: updatedCount,
            skippedCount: skippedCount
        )
    }

    func ingestFinnhubWebhook(payload: FinnhubNewsWebhookRequest, on db: any Database) async throws -> FinnhubNewsWebhookResponse {
        let normalizedArticles = try payload.news.compactMap(normalizeWebhookArticle)
        let trackedUsersBySymbol = try await repo.trackedUserIDs(
            symbols: normalizedArticles.flatMap(\.symbols),
            on: db
        )

        var insertedCount = 0
        var skippedCount = max(payload.news.count - normalizedArticles.count, 0)
        var matchedSymbols = Set<String>()
        var matchedUsers = Set<UUID>()

        for article in normalizedArticles {
            let trackedSymbols = Array(Set(article.symbols.filter { trackedUsersBySymbol[$0] != nil }))
            guard !trackedSymbols.isEmpty else {
                skippedCount += 1
                continue
            }

            matchedSymbols.formUnion(trackedSymbols)
            for symbol in trackedSymbols {
                guard let userIDs = trackedUsersBySymbol[symbol], !userIDs.isEmpty else {
                    skippedCount += 1
                    continue
                }

                matchedUsers.formUnion(userIDs)
                for userID in userIDs {
                    let duplicate = try await findDuplicate(
                        userId: userID,
                        symbol: symbol,
                        article: article,
                        on: db
                    )
                    if duplicate != nil {
                        skippedCount += 1
                        continue
                    }

                    let item = NewsItem(
                        userId: userID,
                        symbol: symbol,
                        headline: article.headline,
                        source: article.source,
                        url: article.url,
                        summary: article.summary,
                        publishedAt: article.publishedAt
                    )
                    try await repo.save(item, on: db)
                    insertedCount += 1
                }
            }
        }

        return FinnhubNewsWebhookResponse(
            provider: "finnhub",
            receivedCount: payload.news.count,
            matchedSymbolsCount: matchedSymbols.count,
            matchedUsersCount: matchedUsers.count,
            insertedCount: insertedCount,
            skippedCount: skippedCount
        )
    }
}

private extension DefaultNewsService {
    enum UpsertNewsResult {
        case inserted
        case updated
        case skipped
    }

    struct NormalizedNewsArticle {
        let symbols: [String]
        let headline: String
        let source: String?
        let url: String?
        let summary: String?
        let publishedAt: Date
    }

    func makeResponse(from model: NewsItem) throws -> NewsItemResponse {
        guard let id = model.id else {
            throw Abort(.internalServerError, reason: "News id missing")
        }

        return NewsItemResponse(
            id: id.uuidString,
            symbol: model.symbol,
            headline: model.headline,
            source: model.source,
            url: model.url,
            summary: model.summary,
            publishedAt: formatISODateTime(model.publishedAt),
            createdAt: model.createdAt.map(formatISODateTime),
            updatedAt: model.updatedAt.map(formatISODateTime)
        )
    }

    func normalizeSymbol(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else {
            throw NewsServiceError.invalidSymbol
        }
        return normalized
    }

    func normalizedSymbolValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.isEmpty ? nil : normalized
    }

    func normalizeHeadline(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw NewsServiceError.invalidHeadline
        }
        return normalized
    }

    func normalizeURL(_ raw: String?) throws -> String? {
        let trimmed = trimToNil(raw)
        guard let trimmed else { return nil }
        guard
            let parsed = URL(string: trimmed),
            let scheme = parsed.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            parsed.host != nil
        else {
            throw NewsServiceError.invalidURL
        }
        return trimmed
    }

    func trimToNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func parsePublishedAt(_ raw: String?) throws -> Date {
        guard let raw = trimToNil(raw) else {
            return Date()
        }

        if let parsed = parseISO8601(raw) {
            return parsed
        }

        throw NewsServiceError.invalidPublishedAt
    }

    func parseISO8601(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) {
            return date
        }

        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: raw)
    }

    func formatISODateTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func normalizeProviderArticle(_ raw: ProviderNewsItem) throws -> NormalizedNewsArticle? {
        guard let symbol = normalizedSymbolValue(raw.symbol) else {
            return nil
        }

        guard let headline = trimToNil(raw.headline) else {
            return nil
        }

        return try NormalizedNewsArticle(
            symbols: [symbol],
            headline: normalizeHeadline(headline),
            source: trimToNil(raw.source),
            url: normalizeURL(raw.url),
            summary: trimToNil(raw.summary),
            publishedAt: raw.publishedAt
        )
    }

    func normalizeWebhookArticle(_ raw: FinnhubNewsWebhookItem) throws -> NormalizedNewsArticle? {
        guard let rawHeadline = trimToNil(raw.headline) else {
            return nil
        }

        let symbols = normalizedWebhookSymbols(from: raw)
        guard !symbols.isEmpty else {
            return nil
        }

        return try NormalizedNewsArticle(
            symbols: symbols,
            headline: normalizeHeadline(rawHeadline),
            source: trimToNil(raw.source),
            url: normalizeURL(raw.url),
            summary: trimToNil(raw.summary),
            publishedAt: normalizeWebhookPublishedAt(raw)
        )
    }

    func normalizedWebhookSymbols(from item: FinnhubNewsWebhookItem) -> [String] {
        let directSymbols = (item.symbols ?? []) + [item.symbol].compactMap(\.self)
        let relatedSymbols = (item.related ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ",;| \n\t"))
        let symbols = directSymbols + relatedSymbols

        return Array(
            Set(
                symbols.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                    .filter { !$0.isEmpty }
            )
        )
    }

    func normalizeWebhookPublishedAt(_ item: FinnhubNewsWebhookItem) throws -> Date {
        if let rawPublishedAt = trimToNil(item.publishedAt) {
            if let parsed = parseISO8601(rawPublishedAt) {
                return parsed
            }
            throw NewsServiceError.invalidPublishedAt
        }

        if let timestamp = item.datetime {
            let normalizedTimestamp = timestamp > 9_999_999_999 ? timestamp / 1000 : timestamp
            return Date(timeIntervalSince1970: normalizedTimestamp)
        }

        return Date()
    }

    func upsertNewsItem(
        userId: UUID,
        symbol: String,
        article: NormalizedNewsArticle,
        on db: any Database
    ) async throws -> UpsertNewsResult {
        if let existing = try await findDuplicate(
            userId: userId,
            symbol: symbol,
            article: article,
            on: db
        ) {
            if apply(article: article, to: existing) {
                try await repo.save(existing, on: db)
                return .updated
            }
            return .skipped
        }

        let item = NewsItem(
            userId: userId,
            symbol: symbol,
            headline: article.headline,
            source: article.source,
            url: article.url,
            summary: article.summary,
            publishedAt: article.publishedAt
        )
        try await repo.save(item, on: db)
        return .inserted
    }

    func findDuplicate(
        userId: UUID,
        symbol: String,
        article: NormalizedNewsArticle,
        on db: any Database
    ) async throws -> NewsItem? {
        let candidates = try await repo.findPotentialDuplicates(
            userId: userId,
            symbol: symbol,
            headline: article.headline,
            url: article.url,
            on: db
        )

        if let candidateURL = trimToNil(article.url) {
            if let exactURLMatch = candidates.first(where: { normalizedDuplicateValue($0.url) == candidateURL }) {
                return exactURLMatch
            }
        }

        return candidates.first(where: { isDuplicate($0, comparedTo: article) })
    }

    func apply(article: NormalizedNewsArticle, to existing: NewsItem) -> Bool {
        let currentURL = trimToNil(existing.url)
        let currentSource = trimToNil(existing.source)
        let currentSummary = trimToNil(existing.summary)

        let needsUpdate =
            existing.headline != article.headline ||
            currentSource != article.source ||
            currentURL != article.url ||
            currentSummary != article.summary ||
            abs(existing.publishedAt.timeIntervalSince(article.publishedAt)) >= 1

        guard needsUpdate else {
            return false
        }

        existing.headline = article.headline
        existing.source = article.source
        existing.url = article.url
        existing.summary = article.summary
        existing.publishedAt = article.publishedAt
        return true
    }

    func isDuplicate(_ existing: NewsItem, comparedTo candidate: NormalizedNewsArticle) -> Bool {
        let existingURL = normalizedDuplicateValue(existing.url)
        let candidateURL = normalizedDuplicateValue(candidate.url)
        let sameURL = existingURL == candidateURL
        let publishedDelta = abs(existing.publishedAt.timeIntervalSince(candidate.publishedAt))
        if sameURL, !candidateURL.isEmpty {
            return true
        }
        return existing.headline == candidate.headline && publishedDelta < 1
    }

    func normalizedDuplicateValue(_ raw: String?) -> String {
        trimToNil(raw) ?? ""
    }
}
