import Foundation
import Vapor

protocol CryptoDataProvider: Sendable {
    func cryptocurrencyList(on req: Request) async throws -> [CryptoAssetResponse]
    func quote(symbol: String, on req: Request) async throws -> [CryptoQuoteResponse]
    func quoteShort(symbol: String, on req: Request) async throws -> [CryptoQuoteShortResponse]
    func batchQuotes(short: Bool, on req: Request) async throws -> [CryptoQuoteShortResponse]
    func historicalLight(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalLightPoint]
    func historicalFull(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalFullPoint]
    func intraday1min(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint]
    func intraday5min(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint]
    func intraday1hour(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint]
}

struct FMPCryptoDataProvider: CryptoDataProvider {
    let baseURL: String
    let apiKey: String

    init(
        baseURL: String = "https://financialmodelingprep.com",
        apiKey: String
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    func cryptocurrencyList(on req: Request) async throws -> [CryptoAssetResponse] {
        try await fetchJSON(path: "/stable/cryptocurrency-list", query: [], on: req)
    }

    func quote(symbols: String, on req: Request) async throws -> [CryptoQuoteResponse] {
        let symbols = try normalizeSymbols(symbols)
        return try await fetchJSON(
            path: "/stable/quote",
            query: [("symbol", symbols)],
            on: req
        )
    }

    func quoteShort(symbol: String, on req: Request) async throws -> [CryptoQuoteShortResponse] {
        let symbol = try normalizeSymbol(symbol)
        return try await fetchJSON(
            path: "/stable/quote-short",
            query: [("symbol", symbol)],
            on: req
        )
    }

    func batchQuotes(short: Bool, on req: Request) async throws -> [CryptoQuoteShortResponse] {
        var query: [(String, String?)] = []
        if short {
            query.append(("short", "true"))
        }
        return try await fetchJSON(
            path: "/stable/batch-crypto-quotes",
            query: query,
            on: req
        )
    }

    func historicalLight(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalLightPoint] {
        let symbol = try normalizeSymbol(symbol)
        var query: [(String, String?)] = [("symbol", symbol)]
        if let from { query.append(("from", from)) }
        if let to { query.append(("to", to)) }
        return try await fetchJSON(
            path: "/stable/historical-price-eod/light",
            query: query,
            on: req
        )
    }

    func historicalFull(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalFullPoint] {
        let symbol = try normalizeSymbol(symbol)
        var query: [(String, String?)] = [("symbol", symbol)]
        if let from { query.append(("from", from)) }
        if let to { query.append(("to", to)) }
        return try await fetchJSON(
            path: "/stable/historical-price-eod/full",
            query: query,
            on: req
        )
    }

    func intraday1min(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint] {
        try await fetchIntraday(interval: "1min", symbol: symbol, from: from, to: to, on: req)
    }

    func intraday5min(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint] {
        try await fetchIntraday(interval: "5min", symbol: symbol, from: from, to: to, on: req)
    }

    func intraday1hour(symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint] {
        try await fetchIntraday(interval: "1hour", symbol: symbol, from: from, to: to, on: req)
    }
}

// MARK: - Private Helpers

private extension FMPCryptoDataProvider {
    func fetchIntraday(interval: String, symbol: String, from: String?, to: String?, on req: Request) async throws -> [CryptoHistoricalPoint] {
        let symbol = try normalizeSymbol(symbol)
        var query: [(String, String?)] = [("symbol", symbol)]
        if let from { query.append(("from", from)) }
        if let to { query.append(("to", to)) }
        return try await fetchJSON(
            path: "/stable/historical-chart/\(interval)",
            query: query,
            on: req
        )
    }

    func fetchJSON<ResponseBody: Decodable>(
        path: String,
        query: [(String, String?)],
        on req: Request
    ) async throws -> ResponseBody {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.serviceUnavailable, reason: "FMP_API_KEY is not configured.")
        }

        let uri = try makeURI(path: path, query: query)
        let response = try await req.client.get(uri) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
        }

        switch response.status {
        case .ok:
            do {
                return try response.content.decode(ResponseBody.self)
            } catch {
                throw Abort(.badGateway, reason: "Failed to decode FMP response for \(path).")
            }

        case .notFound:
            throw Abort(.notFound, reason: "FMP resource not found for \(path).")

        case .unauthorized, .forbidden:
            req.logger.error("FMP rejected crypto request. status=\(response.status.code) url=\(uri)")
            throw Abort(.badGateway, reason: "FMP rejected the request. Check FMP_API_KEY.")

        case .paymentRequired:
            let body = extractResponseBody(response)
            let reason = body.isEmpty
                ? "FMP plan upgrade required for \(path)."
                : "FMP plan upgrade required for \(path). Upstream: \(body)"
            throw Abort(.paymentRequired, reason: reason)

        default:
            let body = extractResponseBody(response)
            let reason = body.isEmpty
                ? "FMP request failed for \(path) with status \(response.status.code)."
                : "FMP request failed for \(path) with status \(response.status.code): \(body)"
            throw Abort(.badGateway, reason: reason)
        }
    }

    func makeURI(path: String, query: [(String, String?)]) throws -> URI {
        let trimmedBaseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: trimmedBaseURL + path) else {
            throw Abort(.internalServerError, reason: "Invalid FMP base URL configuration.")
        }

        var queryItems = query.compactMap { name, value in
            value.map { URLQueryItem(name: name, value: $0) }
        }
        queryItems.append(URLQueryItem(name: "apikey", value: apiKey))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw Abort(.internalServerError, reason: "Unable to build FMP request URL.")
        }

        return URI(string: url.absoluteString)
    }

    func normalizeSymbols(_ raw: String) throws -> String {
        let normalized = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
        
        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "At least one symbol is required.")
        }
        return normalized
    }

    func normalizeSymbol(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "Symbol is required.")
        }
        return normalized
    }

    func extractResponseBody(_ response: ClientResponse) -> String {
        response.body
            .flatMap { buffer in
                buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes)
            }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
