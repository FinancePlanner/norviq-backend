import Foundation
import StockPlanShared
import Vapor

struct FinnhubMarketDataProvider: MarketDataProvider {
    let baseURL: String
    let apiKey: String
    let defaultCurrency: String

    var name: String {
        "finnhub"
    }

    init(
        baseURL: String = "https://finnhub.io/api/v1",
        apiKey: String = Environment.get("FINNHUB_API_KEY")
            ?? "",
        defaultCurrency: String = Environment.get("MARKET_DEFAULT_CURRENCY") ?? "USD"
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.defaultCurrency = defaultCurrency
    }

    func quote(symbol rawSymbol: String, on req: Request) async throws -> MarketProviderQuote {
        let symbol = try normalizeSymbol(rawSymbol)
        let payload: FinnhubQuotePayload = try await fetchJSON(
            path: "/quote",
            query: [("symbol", symbol)],
            on: req
        )
        let profile = try? await fetchCompanyProfile(symbol: symbol, on: req)

        return try mapQuote(
            symbol: symbol,
            quotePayload: payload,
            currency: profile?.currency ?? defaultCurrency
        )
    }

    func history(symbol rawSymbol: String, from: Date?, to: Date?, on req: Request) async throws -> MarketProviderHistory {
        let symbol = try normalizeSymbol(rawSymbol)
        let effectiveTo = to ?? Date()
        let effectiveFrom = from ?? defaultHistoryStartDate(relativeTo: effectiveTo)

        let payload: FinnhubCandlePayload
        do {
            payload = try await fetchJSON(
                path: "/stock/candle",
                query: [
                    ("symbol", symbol),
                    ("resolution", "D"),
                    ("from", String(Int(effectiveFrom.timeIntervalSince1970))),
                    ("to", String(Int(effectiveTo.timeIntervalSince1970))),
                ],
                on: req
            )
        } catch {
            req.logger.warning("Finnhub history request failed for \(symbol): \(error.localizedDescription). Falling back to empty history array.")
            let profile = try? await fetchCompanyProfile(symbol: symbol, on: req)
            return MarketProviderHistory(
                symbol: symbol,
                currency: profile?.currency ?? defaultCurrency,
                bars: []
            )
        }

        let profile = try? await fetchCompanyProfile(symbol: symbol, on: req)

        return mapHistory(
            symbol: symbol,
            candlePayload: payload,
            currency: profile?.currency ?? defaultCurrency
        )
    }

    func search(query rawQuery: String, on req: Request) async throws -> [MarketProviderSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw Abort(.badRequest, reason: "Query is required.")
        }

        let payload: FinnhubSymbolLookupPayload = try await fetchJSON(
            path: "/search",
            query: [("q", query)],
            on: req
        )

        return mapSearchResults(from: payload)
    }

    func fx(base rawBase: String, quote rawQuote: String, on req: Request) async throws -> MarketProviderFxRate {
        let base = try normalizeCurrencyCode(rawBase, field: "base")
        let quote = try normalizeCurrencyCode(rawQuote, field: "quote")

        if base == quote {
            return MarketProviderFxRate(base: base, quote: quote, rate: 1.0, asOf: Date())
        }

        let payload: FinnhubForexRatesPayload = try await fetchJSON(
            path: "/forex/rates",
            query: [("base", base)],
            on: req
        )

        return try mapFxRate(
            base: base,
            quote: quote,
            ratesPayload: payload,
            asOf: Date()
        )
    }

    func profile(symbol rawSymbol: String, on req: Request) async throws -> MarketProviderCompanyProfile? {
        let symbol = try normalizeSymbol(rawSymbol)
        guard let payload = try await fetchCompanyProfile(symbol: symbol, on: req) else {
            return nil
        }
        return mapProfile(symbol: symbol, payload: payload)
    }

    func basicFinancials(symbol rawSymbol: String, on req: Request) async throws -> MarketProviderBasicFinancials? {
        let symbol = try normalizeSymbol(rawSymbol)
        let payload: FinnhubBasicFinancialsPayload = try await fetchJSON(
            path: "/stock/metric",
            query: [
                ("symbol", symbol),
                ("metric", "all"),
            ],
            on: req
        )

        if payload.metric == nil, payload.series == nil, payload.symbol == nil, payload.metricType == nil {
            return nil
        }

        return MarketProviderBasicFinancials(
            symbol: normalizedFallbackValue(payload.symbol, fallback: symbol).uppercased(),
            metricType: normalizedFallbackValue(payload.metricType, fallback: "all"),
            metric: payload.metric ?? [:],
            series: payload.series ?? [:]
        )
    }
}

private extension FinnhubMarketDataProvider {
    func mapProfile(symbol: String, payload: FinnhubCompanyProfilePayload) -> MarketProviderCompanyProfile {
        MarketProviderCompanyProfile(
            symbol: symbol,
            country: payload.country,
            currency: payload.currency,
            estimateCurrency: payload.estimateCurrency,
            exchange: payload.exchange,
            finnhubIndustry: payload.finnhubIndustry,
            ipo: payload.ipo,
            logo: payload.logo,
            marketCapitalization: payload.marketCapitalization,
            name: payload.name,
            phone: payload.phone,
            shareOutstanding: payload.shareOutstanding,
            ticker: payload.ticker,
            weburl: payload.weburl
        )
    }

    func mapQuote(
        symbol: String,
        quotePayload: FinnhubQuotePayload,
        currency: String
    ) throws -> MarketProviderQuote {
        guard let price = quotePayload.currentPrice ?? quotePayload.previousClose else {
            throw Abort(.notFound, reason: "Finnhub quote response did not include a price for \(symbol).")
        }

        let asOf = quotePayload.timestamp.map(Date.init(timeIntervalSince1970:)) ?? Date()
        return MarketProviderQuote(
            symbol: symbol,
            price: price,
            change: quotePayload.change,
            percentChange: quotePayload.percentChange,
            high: quotePayload.high,
            low: quotePayload.low,
            open: quotePayload.open,
            previousClose: quotePayload.previousClose,
            currency: normalizedFallbackValue(currency, fallback: defaultCurrency),
            asOf: asOf
        )
    }

    func mapHistory(
        symbol: String,
        candlePayload: FinnhubCandlePayload,
        currency: String
    ) -> MarketProviderHistory {
        guard candlePayload.status?.lowercased() != "no_data" else {
            return MarketProviderHistory(symbol: symbol, currency: normalizedFallbackValue(currency, fallback: defaultCurrency), bars: [])
        }

        let opens = candlePayload.open ?? []
        let highs = candlePayload.high ?? []
        let lows = candlePayload.low ?? []
        let closes = candlePayload.close ?? []
        let timestamps = candlePayload.timestamps ?? []
        let volumes = candlePayload.volume ?? []

        let count = min(opens.count, highs.count, lows.count, closes.count, timestamps.count)
        guard count > 0 else {
            return MarketProviderHistory(symbol: symbol, currency: normalizedFallbackValue(currency, fallback: defaultCurrency), bars: [])
        }

        var bars: [MarketProviderPriceBar] = []
        bars.reserveCapacity(count)

        for index in 0 ..< count {
            let volume = index < volumes.count ? Int(volumes[index].rounded()) : nil
            bars.append(
                MarketProviderPriceBar(
                    date: Date(timeIntervalSince1970: TimeInterval(timestamps[index])),
                    open: opens[index],
                    high: highs[index],
                    low: lows[index],
                    close: closes[index],
                    volume: volume
                )
            )
        }

        return MarketProviderHistory(
            symbol: symbol,
            currency: normalizedFallbackValue(currency, fallback: defaultCurrency),
            bars: bars.sorted { $0.date < $1.date }
        )
    }

    func mapSearchResults(from payload: FinnhubSymbolLookupPayload) -> [MarketProviderSearchResult] {
        (payload.result ?? []).compactMap { item in
            let symbol = normalizedFallbackValue(item.symbol, fallback: item.displaySymbol ?? "")
            guard !symbol.isEmpty else {
                return nil
            }

            let displaySymbol = normalizedFallbackValue(item.displaySymbol, fallback: symbol)
            let name = normalizedFallbackValue(item.description, fallback: displaySymbol)
            let exchange = inferExchange(from: symbol, securityType: item.type)

            return MarketProviderSearchResult(
                symbol: symbol.uppercased(),
                name: name,
                exchange: exchange,
                currency: defaultCurrency,
                conid: displaySymbol
            )
        }
    }

    func mapFxRate(
        base: String,
        quote: String,
        ratesPayload: FinnhubForexRatesPayload,
        asOf: Date
    ) throws -> MarketProviderFxRate {
        guard let quotes = ratesPayload.quote, let rate = quotes[quote] else {
            throw Abort(.notFound, reason: "Finnhub FX response did not include a rate for \(base)/\(quote).")
        }

        return MarketProviderFxRate(
            base: normalizedFallbackValue(ratesPayload.base, fallback: base).uppercased(),
            quote: quote,
            rate: rate,
            asOf: asOf
        )
    }
}

private extension FinnhubMarketDataProvider {
    func fetchCompanyProfile(symbol: String, on req: Request) async throws -> FinnhubCompanyProfilePayload? {
        let payload: FinnhubCompanyProfilePayload = try await fetchJSON(
            path: "/stock/profile2",
            query: [("symbol", symbol)],
            on: req
        )

        if payload.ticker == nil, payload.name == nil, payload.currency == nil, payload.exchange == nil {
            return nil
        }

        return payload
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
            clientRequest.timeout = .seconds(15)
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
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
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

    func defaultHistoryStartDate(relativeTo date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(byAdding: .year, value: -1, to: date) ?? date.addingTimeInterval(-31_536_000)
    }

    func normalizeSymbol(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "Symbol is required.")
        }
        return normalized
    }

    func normalizeCurrencyCode(_ raw: String, field: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.count == 3 else {
            throw Abort(.badRequest, reason: "Invalid \(field) currency code.")
        }
        return normalized
    }

    func normalizedFallbackValue(_ raw: String?, fallback: String) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    func inferExchange(from symbol: String, securityType: String?) -> String {
        if let exchangeCode = symbol.split(separator: ".").last, symbol.contains(".") {
            return String(exchangeCode).uppercased()
        }

        let normalizedType = securityType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalizedType.isEmpty ? "UNKNOWN" : normalizedType
    }
}

private struct FinnhubQuotePayload: Decodable {
    let currentPrice: Double?
    let change: Double?
    let percentChange: Double?
    let high: Double?
    let low: Double?
    let open: Double?
    let previousClose: Double?
    let timestamp: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case currentPrice = "c"
        case change = "d"
        case percentChange = "dp"
        case high = "h"
        case low = "l"
        case open = "o"
        case previousClose = "pc"
        case timestamp = "t"
    }
}

private struct FinnhubCandlePayload: Decodable {
    let close: [Double]?
    let high: [Double]?
    let low: [Double]?
    let open: [Double]?
    let status: String?
    let timestamps: [TimeInterval]?
    let volume: [Double]?

    enum CodingKeys: String, CodingKey {
        case close = "c"
        case high = "h"
        case low = "l"
        case open = "o"
        case status = "s"
        case timestamps = "t"
        case volume = "v"
    }
}

private struct FinnhubSymbolLookupPayload: Decodable {
    let count: Int?
    let result: [FinnhubSymbolLookupItem]?
}

private struct FinnhubSymbolLookupItem: Decodable {
    let description: String?
    let displaySymbol: String?
    let symbol: String?
    let type: String?
}

private struct FinnhubCompanyProfilePayload: Decodable {
    let country: String?
    let currency: String?
    let estimateCurrency: String?
    let exchange: String?
    let finnhubIndustry: String?
    let ipo: String?
    let logo: String?
    let marketCapitalization: Double?
    let name: String?
    let phone: String?
    let shareOutstanding: Double?
    let ticker: String?
    let weburl: String?
}

private struct FinnhubForexRatesPayload: Decodable {
    let base: String?
    let quote: [String: Double]?
}

private struct FinnhubBasicFinancialsPayload: Decodable {
    let metric: [String: BasicFinancialMetricValue]?
    let metricType: String?
    let series: [String: [String: [BasicFinancialSeriesPoint]]]?
    let symbol: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        metricType = try container.decodeIfPresent(String.self, forKey: .metricType)
        metric = try container.decodeLossyMetricDictionaryIfPresent(forKey: .metric)
        series = try container.decodeLossySeriesIfPresent(forKey: .series)
    }

    enum CodingKeys: String, CodingKey {
        case metric
        case metricType
        case series
        case symbol
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }
}

private extension KeyedDecodingContainer where Key == FinnhubBasicFinancialsPayload.CodingKeys {
    func decodeLossyMetricDictionaryIfPresent(
        forKey key: Key
    ) throws -> [String: BasicFinancialMetricValue]? {
        guard contains(key), try !decodeNil(forKey: key) else {
            return nil
        }

        let nested = try nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
        var values: [String: BasicFinancialMetricValue] = [:]
        for nestedKey in nested.allKeys {
            if let value = try? nested.decode(BasicFinancialMetricValue.self, forKey: nestedKey) {
                values[nestedKey.stringValue] = value
            }
        }
        return values
    }

    func decodeLossySeriesIfPresent(
        forKey key: Key
    ) throws -> [String: [String: [BasicFinancialSeriesPoint]]]? {
        guard contains(key), try !decodeNil(forKey: key) else {
            return nil
        }

        let frequencies = try nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
        var result: [String: [String: [BasicFinancialSeriesPoint]]] = [:]

        for frequencyKey in frequencies.allKeys {
            guard let metrics = try? frequencies.nestedContainer(keyedBy: AnyCodingKey.self, forKey: frequencyKey) else {
                continue
            }

            var metricSeries: [String: [BasicFinancialSeriesPoint]] = [:]
            for metricKey in metrics.allKeys {
                if let points = try? metrics.decode([BasicFinancialSeriesPoint].self, forKey: metricKey) {
                    metricSeries[metricKey.stringValue] = points
                }
            }

            result[frequencyKey.stringValue] = metricSeries
        }

        return result
    }
}
