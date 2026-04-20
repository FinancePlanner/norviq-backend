import Foundation
import StockPlanShared
import Vapor

protocol FMPMarketDataProvider: Sendable {
    var name: String { get }

    func cashFlowStatement(
        symbol: String,
        limit: Int?,
        period: String?,
        on req: Request
    ) async throws -> [CashFlowStatementResponse]
    func balanceSheetStatement(
        symbol: String,
        limit: Int?,
        period: String?,
        on req: Request
    ) async throws -> [BalanceSheetStatementResponse]
    func ratiosTTM(symbol: String, on req: Request) async throws -> [RatiosTTMResponse]
    func gradesConsensus(symbol: String, on req: Request) async throws -> [GradesConsensusResponse]
    func financialGrowth(
        symbol: String,
        limit: Int?,
        period: String?,
        on req: Request
    ) async throws -> [FinancialGrowthResponse]
    func analystEstimates(
        symbol: String,
        period: String,
        page: Int?,
        limit: Int?,
        on req: Request
    ) async throws -> [AnalystEstimatesResponse]
    func ratios(
        symbol: String,
        limit: Int?,
        period: String?,
        on req: Request
    ) async throws -> [RatiosResponse]
    func earnings(
        symbol: String,
        limit: Int?,
        on req: Request
    ) async throws -> [EarningsResponse]
    func earningsCalendar(
        from: Date?,
        to: Date?,
        on req: Request
    ) async throws -> [EarningsResponse]
    func historicalSectorPerformance(
        sector: String,
        exchange: String?,
        from: Date?,
        to: Date?,
        on req: Request
    ) async throws -> [HistoricalSectorPerformanceResponse]
    func fetchGeneralMarketNews(
        page: Int?,
        limit: Int?,
        from: Date?,
        to: Date?,
        on req: Request
    ) async throws -> [FMPMarketNewsItem]

    // Stock price chart (intraday + EOD)
    func stockIntraday(
        interval: String,
        symbol: String,
        from: String?,
        to: String?,
        on req: Request
    ) async throws -> [CryptoHistoricalPoint]
    func stockHistoricalEOD(
        symbol: String,
        from: String?,
        to: String?,
        on req: Request
    ) async throws -> [CryptoHistoricalLightPoint]
}

struct FMPMarketNewsItem: Codable, Sendable {
    let symbol: String?
    let publishedDate: String?
    let title: String?
    let image: String?
    let site: String?
    let publisher: String?
    let text: String?
    let url: String?
}

struct LiveFMPMarketDataProvider: FMPMarketDataProvider, CryptoDataProvider {
    let baseURL: String
    let apiKey: String

    var name: String { "fmp" }

    init(
        baseURL: String = "https://financialmodelingprep.com",
        apiKey: String = Environment.get("FMP_API_KEY") ?? ""
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    // MARK: - CryptoDataProvider

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

    func historicalLight(symbol: String, from: String?, to: String?, on req: Request) async throws
        -> [CryptoHistoricalLightPoint] {
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

    func historicalFull(symbol: String, from: String?, to: String?, on req: Request) async throws
        -> [CryptoHistoricalFullPoint] {
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

    func intraday1min(symbol: String, from: String?, to: String?, on req: Request) async throws
        -> [CryptoHistoricalPoint] {
        try await fetchIntraday(interval: "1min", symbol: symbol, from: from, to: to, on: req)
    }

    func intraday5min(symbol: String, from: String?, to: String?, on req: Request) async throws
        -> [CryptoHistoricalPoint] {
        try await fetchIntraday(interval: "5min", symbol: symbol, from: from, to: to, on: req)
    }

    func intraday1hour(symbol: String, from: String?, to: String?, on req: Request) async throws
        -> [CryptoHistoricalPoint] {
        try await fetchIntraday(interval: "1hour", symbol: symbol, from: from, to: to, on: req)
    }

    func fetchCryptoNews(
        symbol: String?,
        page: Int?,
        limit: Int?,
        from: String?,
        to: String?,
        on req: Request
    ) async throws -> [FMPMarketNewsItem] {
        var query: [(String, String?)] = []
        if let symbol { query.append(("symbol", try normalizeSymbol(symbol))) }
        if let page { query.append(("page", String(page))) }
        if let limit { query.append(("limit", String(limit))) }
        if let from { query.append(("from", from)) }
        if let to { query.append(("to", to)) }

        return try await fetchJSON(
            path: "/stable/news/crypto-latest",
            query: query,
            on: req
        )
    }

    private func fetchIntraday(
        interval: String, symbol: String, from: String?, to: String?, on req: Request
    ) async throws -> [CryptoHistoricalPoint] {
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

    private func normalizeSymbols(_ raw: String) throws -> String {
        let normalized = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
            .joined(separator: ",")

        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "At least one symbol is required.")
        }
        return normalized
    }

    // MARK: - FMPMarketDataProvider

    func cashFlowStatement(
        symbol rawSymbol: String,
        limit: Int?,
        period rawPeriod: String?,
        on req: Request
    ) async throws -> [CashFlowStatementResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let period = normalizedOptionalValue(rawPeriod)

        var query: [(String, String?)] = [("symbol", symbol)]
        if let limit {
            query.append(("limit", String(limit)))
        }
        if let period {
            query.append(("period", period))
        }

        return try await fetchJSON(
            path: "/stable/cash-flow-statement",
            query: query,
            on: req
        )
    }

    func ratiosTTM(symbol rawSymbol: String, on req: Request) async throws -> [RatiosTTMResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        return try await fetchJSON(
            path: "/stable/ratios-ttm",
            query: [("symbol", symbol)],
            on: req
        )
    }

    func balanceSheetStatement(
        symbol rawSymbol: String,
        limit: Int?,
        period rawPeriod: String?,
        on req: Request
    ) async throws -> [BalanceSheetStatementResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let period = normalizedOptionalValue(rawPeriod)

        var query: [(String, String?)] = [("symbol", symbol)]
        if let limit {
            query.append(("limit", String(limit)))
        }
        if let period {
            query.append(("period", period))
        }

        return try await fetchJSON(
            path: "/stable/balance-sheet-statement",
            query: query,
            on: req
        )
    }

    func gradesConsensus(symbol rawSymbol: String, on req: Request) async throws
        -> [GradesConsensusResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        return try await fetchJSON(
            path: "/stable/grades-consensus",
            query: [("symbol", symbol)],
            on: req
        )
    }

    func financialGrowth(
        symbol rawSymbol: String,
        limit: Int?,
        period rawPeriod: String?,
        on req: Request
    ) async throws -> [FinancialGrowthResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let period = normalizedOptionalValue(rawPeriod)

        var query: [(String, String?)] = [("symbol", symbol)]
        if let limit {
            query.append(("limit", String(limit)))
        }
        if let period {
            query.append(("period", period))
        }

        return try await fetchJSON(
            path: "/stable/financial-growth",
            query: query,
            on: req
        )
    }

    func analystEstimates(
        symbol rawSymbol: String,
        period rawPeriod: String,
        page: Int?,
        limit: Int?,
        on req: Request
    ) async throws -> [AnalystEstimatesResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let period = try normalizeRequiredValue(rawPeriod, field: "period")

        var query: [(String, String?)] = [("symbol", symbol), ("period", period)]
        if let page {
            query.append(("page", String(page)))
        }
        if let limit {
            query.append(("limit", String(limit)))
        }

        return try await fetchJSON(
            path: "/stable/analyst-estimates",
            query: query,
            on: req
        )
    }

    func ratios(
        symbol rawSymbol: String,
        limit: Int?,
        period rawPeriod: String?,
        on req: Request
    ) async throws -> [RatiosResponse] {
        let symbol = try normalizeSymbol(rawSymbol)
        let period = normalizedOptionalValue(rawPeriod)

        var query: [(String, String?)] = [("symbol", symbol)]
        if let limit {
            query.append(("limit", String(limit)))
        }
        if let period {
            query.append(("period", period))
        }

        return try await fetchJSON(
            path: "/stable/ratios",
            query: query,
            on: req
        )
    }

    func earnings(
        symbol rawSymbol: String,
        limit: Int?,
        on req: Request
    ) async throws -> [EarningsResponse] {
        let symbol = try normalizeSymbol(rawSymbol)

        var query: [(String, String?)] = [("symbol", symbol)]
        if let limit {
            query.append(("limit", String(limit)))
        }

        return try await fetchJSON(
            path: "/stable/earnings",
            query: query,
            on: req
        )
    }

    func earningsCalendar(
        from: Date?,
        to: Date?,
        on req: Request
    ) async throws -> [EarningsResponse] {
        var query: [(String, String?)] = []
        if let from {
            query.append(("from", formatISODateOnly(from)))
        }
        if let to {
            query.append(("to", formatISODateOnly(to)))
        }

        return try await fetchJSON(
            path: "/stable/earnings-calendar",
            query: query,
            on: req
        )
    }

    func historicalSectorPerformance(
        sector rawSector: String,
        exchange rawExchange: String?,
        from: Date?,
        to: Date?,
        on req: Request
    ) async throws -> [HistoricalSectorPerformanceResponse] {
        let sector = try normalizeRequiredValue(rawSector, field: "sector")
        let exchange = normalizedOptionalValue(rawExchange)

        return try await fetchJSON(
            path: "/stable/historical-sector-performance",
            query: [
                ("sector", sector),
                ("exchange", exchange),
                ("from", from.map(formatISODateOnly)),
                ("to", to.map(formatISODateOnly))
            ],
            on: req
        )
    }

    func fetchGeneralMarketNews(
        page: Int?,
        limit: Int?,
        from: Date?,
        to: Date?,
        on req: Request
    ) async throws -> [FMPMarketNewsItem] {
        var query: [(String, String?)] = []
        if let page { query.append(("page", String(page))) }
        if let limit { query.append(("limit", String(limit))) }
        if let from { query.append(("from", formatISODateOnly(from))) }
        if let to { query.append(("to", formatISODateOnly(to))) }

        return try await fetchJSON(
            path: "/stable/news/stock-latest",
            query: query,
            on: req
        )
    }

    // MARK: - Stock Price Chart

    func stockIntraday(
        interval: String,
        symbol rawSymbol: String,
        from: String?,
        to: String?,
        on req: Request
    ) async throws -> [CryptoHistoricalPoint] {
        let symbol = try normalizeSymbol(rawSymbol)
        var query: [(String, String?)] = [("symbol", symbol)]
        if let from { query.append(("from", from)) }
        if let to { query.append(("to", to)) }
        return try await fetchJSON(
            path: "/stable/historical-chart/\(interval)",
            query: query,
            on: req
        )
    }

    func stockHistoricalEOD(
        symbol rawSymbol: String,
        from: String?,
        to: String?,
        on req: Request
    ) async throws -> [CryptoHistoricalLightPoint] {
        let symbol = try normalizeSymbol(rawSymbol)
        var query: [(String, String?)] = [("symbol", symbol)]
        if let from { query.append(("from", from)) }
        if let to { query.append(("to", to)) }
        return try await fetchJSON(
            path: "/stable/historical-price-eod/light",
            query: query,
            on: req
        )
    }
}

extension LiveFMPMarketDataProvider {
    fileprivate func fetchJSON<ResponseBody: Decodable>(
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
            let body = extractResponseBody(response)
            let maskedApiKey =
                apiKey.count > 4
                ? String(repeating: "*", count: apiKey.count - 4) + apiKey.suffix(4)
                : "****"
            req.logger.error(
                "FMP rejected the request. status=\(response.status.code) url=\(uri) apiKeyLength=\(apiKey.count) maskedKey=\(maskedApiKey) response=\(body)"
            )
            throw Abort(.badGateway, reason: "FMP rejected the request. Check FMP_API_KEY.")

        case .paymentRequired:
            let body = extractResponseBody(response)
            let reason =
                body.isEmpty
                ? "FMP plan upgrade required for \(path). This endpoint is not available for the requested symbol on the current subscription."
                : "FMP plan upgrade required for \(path). This endpoint is not available for the requested symbol on the current subscription. Upstream response: \(body)"
            throw Abort(.paymentRequired, reason: reason)

        default:
            let body = extractResponseBody(response)
            let reason =
                body.isEmpty
                ? "FMP request failed for \(path) with status \(response.status.code)."
                : "FMP request failed for \(path) with status \(response.status.code): \(body)"
            throw Abort(.badGateway, reason: reason)
        }
    }

    fileprivate func makeURI(path: String, query: [(String, String?)]) throws -> URI {
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

    fileprivate func normalizeSymbol(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "Symbol is required.")
        }
        return normalized
    }

    fileprivate func normalizeRequiredValue(_ raw: String, field: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "\(field.capitalized) is required.")
        }
        return normalized
    }

    fileprivate func normalizedOptionalValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    fileprivate func extractResponseBody(_ response: ClientResponse) -> String {
        response.body
            .flatMap { buffer in
                buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes)
            }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    fileprivate func formatISODateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
