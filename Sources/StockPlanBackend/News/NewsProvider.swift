import Vapor
import Foundation

struct ProviderNewsItem: Sendable {
    let symbol: String
    let headline: String
    let source: String?
    let url: String?
    let summary: String?
    let image: String?
    let publishedAt: Date
}

protocol NewsProvider: Sendable {
    var name: String { get }
    func fetch(symbols: [String], on req: Request) async throws -> [ProviderNewsItem]
    func fetchGeneral(on req: Request) async throws -> [ProviderNewsItem]
}

struct FinnhubNewsProvider: NewsProvider {
    let baseURL: String
    let apiKey: String
    let lookbackDays: Int
    let maxArticlesPerSymbol: Int?

    var name: String { "finnhub" }

    init(
        baseURL: String = "https://finnhub.io/api/v1",
        apiKey: String = Environment.get("FINNHUB_API_KEY") ?? "",
        lookbackDays: Int = 7,
        maxArticlesPerSymbol: Int? = 25
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.lookbackDays = max(1, lookbackDays)
        self.maxArticlesPerSymbol = maxArticlesPerSymbol
    }

    func fetch(symbols: [String], on req: Request) async throws -> [ProviderNewsItem] {
        let normalizedSymbols = Array(
            Set(
                symbols.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                }
                .filter { !$0.isEmpty }
            )
        )
        .sorted()

        guard !normalizedSymbols.isEmpty else {
            return []
        }

        let window = companyNewsWindow(relativeTo: Date())
        var items: [ProviderNewsItem] = []

        for symbol in normalizedSymbols {
            let payload: [FinnhubCompanyNewsPayload] = try await fetchJSON(
                path: "/company-news",
                query: [
                    ("symbol", symbol),
                    ("from", window.from),
                    ("to", window.to)
                ],
                on: req
            )

            let normalizedItems = payload.compactMap { article in
                ProviderNewsItem(
                    symbol: symbol,
                    headline: article.headline ?? "",
                    source: article.source,
                    url: article.url,
                    summary: article.summary,
                    image: article.image,
                    publishedAt: article.datetime.map(Date.init(timeIntervalSince1970:)) ?? Date()
                )
            }

            if let maxArticlesPerSymbol, maxArticlesPerSymbol > 0 {
                items.append(contentsOf: normalizedItems.prefix(maxArticlesPerSymbol))
            } else {
                items.append(contentsOf: normalizedItems)
            }
        }

        return items
    }

    func fetchGeneral(on req: Request) async throws -> [ProviderNewsItem] {
        let payload: [FinnhubCompanyNewsPayload] = try await fetchJSON(
            path: "/news",
            query: [("category", "general")],
            on: req
        )

        return payload.compactMap { article in
            ProviderNewsItem(
                symbol: "GENERAL",
                headline: article.headline ?? "",
                source: article.source,
                url: article.url,
                summary: article.summary,
                image: article.image,
                publishedAt: article.datetime.map(Date.init(timeIntervalSince1970:)) ?? Date()
            )
        }
    }
}

struct ExternalAPINewsProvider: NewsProvider {
    let name: String = "external_api"

    func fetch(symbols: [String], on req: Request) async throws -> [ProviderNewsItem] {
        throw Abort(.notImplemented, reason: "External API news provider fetch is not implemented yet.")
    }

    func fetchGeneral(on req: Request) async throws -> [ProviderNewsItem] {
        throw Abort(.notImplemented, reason: "External API news provider fetchGeneral is not implemented yet.")
    }
}

struct RSSNewsProvider: NewsProvider {
    let name: String = "rss"

    func fetch(symbols: [String], on req: Request) async throws -> [ProviderNewsItem] {
        throw Abort(.notImplemented, reason: "RSS news provider fetch is not implemented yet.")
    }

    func fetchGeneral(on req: Request) async throws -> [ProviderNewsItem] {
        throw Abort(.notImplemented, reason: "RSS news provider fetchGeneral is not implemented yet.")
    }
}

private extension FinnhubNewsProvider {
    struct CompanyNewsWindow: Sendable {
        let from: String
        let to: String
    }

    func fetchJSON<ResponseBody: Decodable>(
        path: String,
        query: [(String, String)],
        on req: Request
    ) async throws -> ResponseBody {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.serviceUnavailable, reason: "FINNHUB_API_KEY is not configured.")
        }

        let uri = try makeURI(path: path, query: query)
        let response = try await req.client.get(uri) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: "X-Finnhub-Token", value: apiKey)
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
        }

        switch response.status {
        case .ok:
            do {
                return try response.content.decode(ResponseBody.self)
            } catch {
                throw Abort(.badGateway, reason: "Failed to decode Finnhub response for \(path).")
            }

        case .notFound:
            throw Abort(.notFound, reason: "Finnhub resource not found for \(path).")

        case .unauthorized, .forbidden:
            throw Abort(.badGateway, reason: "Finnhub rejected the request. Check FINNHUB_API_KEY.")

        default:
            let body = response.body
                .flatMap { buffer in
                    buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes)
                }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let reason = body.isEmpty
                ? "Finnhub request failed for \(path) with status \(response.status.code)."
                : "Finnhub request failed for \(path) with status \(response.status.code): \(body)"
            throw Abort(.badGateway, reason: reason)
        }
    }

    func makeURI(path: String, query: [(String, String)]) throws -> URI {
        let trimmedBaseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: trimmedBaseURL + path) else {
            throw Abort(.internalServerError, reason: "Invalid Finnhub base URL configuration.")
        }

        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }

        guard let url = components.url else {
            throw Abort(.internalServerError, reason: "Unable to build Finnhub request URL.")
        }

        return URI(string: url.absoluteString)
    }

    func companyNewsWindow(relativeTo date: Date) -> CompanyNewsWindow {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

        let start = calendar.date(byAdding: .day, value: -(lookbackDays - 1), to: date) ?? date
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        return CompanyNewsWindow(
            from: formatter.string(from: start),
            to: formatter.string(from: date)
        )
    }
}

private struct FinnhubCompanyNewsPayload: Decodable {
    let category: String?
    let datetime: TimeInterval?
    let headline: String?
    let id: Int?
    let image: String?
    let related: String?
    let source: String?
    let summary: String?
    let url: String?
}
