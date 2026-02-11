import Vapor
import Fluent
import Foundation

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
            return .notFound
        case .invalidSymbol, .invalidHeadline, .invalidURL, .invalidPublishedAt:
            return .badRequest
        }
    }

    var reason: String {
        switch self {
        case .notFound:
            return "News item not found."
        case .invalidSymbol:
            return "Invalid symbol."
        case .invalidHeadline:
            return "Invalid headline."
        case .invalidURL:
            return "Invalid url."
        case .invalidPublishedAt:
            return "Invalid publishedAt. Expected ISO8601 datetime."
        }
    }
}

protocol NewsService: Sendable {
    func list(userId: UUID, symbol: String?, on db: any Database) async throws -> [NewsItemResponse]
    func feed(userId: UUID, limit: Int?, on db: any Database) async throws -> [NewsItemResponse]
    func get(id: UUID, userId: UUID, on db: any Database) async throws -> NewsItemResponse
    func create(payload: NewsItemRequest, userId: UUID, on db: any Database) async throws -> NewsItemResponse
    func update(id: UUID, payload: NewsItemRequest, userId: UUID, on db: any Database) async throws -> NewsItemResponse
    func delete(id: UUID, userId: UUID, on db: any Database) async throws
    func syncNews(userId: UUID, on req: Request) async throws -> NewsSyncResponse
}

struct DefaultNewsService: NewsService {
    let repo: any NewsRepository
    let provider: (any NewsProvider)?

    init(repo: any NewsRepository = DatabaseNewsRepository(), provider: (any NewsProvider)? = nil) {
        self.repo = repo
        self.provider = provider
    }

    func list(userId: UUID, symbol: String?, on db: any Database) async throws -> [NewsItemResponse] {
        let normalized = normalizedSymbolValue(symbol)
        let items = try await repo.list(userId: userId, symbol: normalized, limit: nil, on: db)
        return try items.map(makeResponse)
    }

    func feed(userId: UUID, limit: Int?, on db: any Database) async throws -> [NewsItemResponse] {
        let clampedLimit = max(1, min(limit ?? 50, 200))
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
        let model = NewsItem(
            userId: userId,
            symbol: try normalizeSymbol(payload.symbol),
            headline: try normalizeHeadline(payload.headline),
            source: trimToNil(payload.source),
            url: try normalizeURL(payload.url),
            summary: trimToNil(payload.summary),
            publishedAt: try parsePublishedAt(payload.publishedAt)
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
                reason: "News provider not configured. Configure a NewsProvider and implement fetch logic."
            )
        }

        let symbols = try await repo.trackedSymbols(userId: userId, on: req.db)
            .compactMap { normalizedSymbolValue($0) }
        let fetched = try await provider.fetch(symbols: symbols, on: req)

        // Scaffolding phase: provider fetch is wired, persistence/upsert logic comes next.
        return NewsSyncResponse(
            provider: provider.name,
            symbolsCount: symbols.count,
            fetchedCount: fetched.count,
            insertedCount: 0,
            updatedCount: 0,
            skippedCount: fetched.count
        )
    }
}

private extension DefaultNewsService {
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
            (scheme == "http" || scheme == "https"),
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
}
