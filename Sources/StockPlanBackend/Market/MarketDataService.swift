import Vapor
import Fluent
import Foundation
import Redis

protocol MarketDataService: Sendable {
    func quote(symbol: String, on req: Request) async throws -> QuoteResponse
    func quoteBatch(symbols: [String], on req: Request) async throws -> QuoteBatchResponse
    func history(symbol: String, from: String?, to: String?, on req: Request) async throws -> HistoryResponse
    func archivedHistory(symbol: String, from: String?, to: String?, on req: Request) async throws -> HistoryResponse
    func refreshHistory(symbol: String, from: String?, to: String?, on req: Request) async throws -> HistoryResponse
    func search(query: String, on req: Request) async throws -> [SearchResultResponse]
    func fx(pair: String, on req: Request) async throws -> FxRateResponse
    func profile(symbol: String, on req: Request) async throws -> CompanyProfileResponse
}

struct MarketDataCacheConfig: Sendable {
    let quoteTTLSeconds: Int
    let historyTTLSeconds: Int
    let searchTTLSeconds: Int
    let fxTTLSeconds: Int
    let profileTTLSeconds: Int
    let defaultCurrency: String

    static func fromEnvironment() -> MarketDataCacheConfig {
        let quoteTTL = Environment.get("MARKET_TTL_QUOTE_SECONDS").flatMap(Int.init(_:)) ?? 20
        let historyTTL = Environment.get("MARKET_TTL_HISTORY_SECONDS").flatMap(Int.init(_:)) ?? 86_400
        let searchTTL = Environment.get("MARKET_TTL_SEARCH_SECONDS").flatMap(Int.init(_:)) ?? 3_600
        let fxTTL = Environment.get("MARKET_TTL_FX_SECONDS").flatMap(Int.init(_:)) ?? 86_400
        let profileTTL = Environment.get("MARKET_TTL_PROFILE_SECONDS").flatMap(Int.init(_:)) ?? 86_400
        let currency = Environment.get("MARKET_DEFAULT_CURRENCY") ?? "USD"

        return .init(
            quoteTTLSeconds: max(1, quoteTTL),
            historyTTLSeconds: max(60, historyTTL),
            searchTTLSeconds: max(60, searchTTL),
            fxTTLSeconds: max(60, fxTTL),
            profileTTLSeconds: max(60, profileTTL),
            defaultCurrency: currency.uppercased()
        )
    }
}

struct DefaultMarketDataService: MarketDataService {
    let provider: any MarketDataProvider
    let cacheConfig: MarketDataCacheConfig

    func quote(symbol rawSymbol: String, on req: Request) async throws -> QuoteResponse {
        let symbol = try normalizeSymbol(rawSymbol)
        let now = Date()
        let providerName = provider.name
        let redisKey = makeQuoteRedisKey(provider: providerName, symbol: symbol)

        if let hotCached: QuoteResponse = await redisGetValue(redisKey, as: QuoteResponse.self, on: req) {
            return hotCached
        }

        let existing = try await QuoteCache.query(on: req.db)
            .filter(\.$provider == providerName)
            .filter(\.$symbol == symbol)
            .first()

        if let existing, isFresh(existing.asOf, ttlSeconds: cacheConfig.quoteTTLSeconds, now: now) {
            let response = makeQuoteResponse(from: existing)
            await redisSetValue(redisKey, value: response, ttlSeconds: cacheConfig.quoteTTLSeconds, on: req)
            return response
        }

        do {
            let fresh = try await provider.quote(symbol: symbol, on: req)
            let cache = try await upsertQuoteCache(fresh, provider: providerName, on: req.db)
            let response = makeQuoteResponse(from: cache)
            await redisSetValue(redisKey, value: response, ttlSeconds: cacheConfig.quoteTTLSeconds, on: req)
            return response
        } catch {
            if let existing {
                req.logger.warning("market.quote stale fallback symbol=\(symbol) provider=\(providerName)")
                let response = makeQuoteResponse(from: existing)
                await redisSetValue(redisKey, value: response, ttlSeconds: cacheConfig.quoteTTLSeconds, on: req)
                return response
            }
            throw mapProviderError(error, operation: "quote")
        }
    }

    func quoteBatch(symbols rawSymbols: [String], on req: Request) async throws -> QuoteBatchResponse {
        var seen: Set<String> = []
        let normalized = try rawSymbols
            .map(normalizeSymbol)
            .filter { seen.insert($0).inserted }

        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "At least one symbol is required.")
        }

        guard normalized.count <= 100 else {
            throw Abort(.badRequest, reason: "Maximum 100 symbols per batch request.")
        }

        var quotes: [QuoteResponse] = []
        quotes.reserveCapacity(normalized.count)
        for symbol in normalized {
            let quote = try await quote(symbol: symbol, on: req)
            quotes.append(quote)
        }

        return QuoteBatchResponse(quotes: quotes)
    }

    func history(symbol rawSymbol: String, from rawFrom: String?, to rawTo: String?, on req: Request) async throws -> HistoryResponse {
        let symbol = try normalizeSymbol(rawSymbol)
        let fromDate = try parseOptionalDateOnly(rawFrom, field: "from")
        let toDate = try parseOptionalDateOnly(rawTo, field: "to")
        let now = Date()
        let redisKey = makeHistoryRedisKey(
            provider: provider.name,
            symbol: symbol,
            from: fromDate,
            to: toDate
        )

        if let fromDate, let toDate, fromDate > toDate {
            throw Abort(.badRequest, reason: "`from` must be on or before `to`.")
        }

        if let hotCached: HistoryResponse = await redisGetValue(redisKey, as: HistoryResponse.self, on: req) {
            return hotCached
        }

        let cachedBars = try await loadCachedHistory(symbol: symbol, from: fromDate, to: toDate, on: req.db)
        if isHistoryFresh(cachedBars, now: now) {
            let response = HistoryResponse(
                symbol: symbol,
                currency: cacheConfig.defaultCurrency,
                bars: cachedBars.map(makePriceBarResponse)
            )
            await redisSetValue(redisKey, value: response, ttlSeconds: cacheConfig.historyTTLSeconds, on: req)
            return response
        }

        do {
            let fresh = try await provider.history(symbol: symbol, from: fromDate, to: toDate, on: req)
            try await upsertHistoryBars(symbol: symbol, bars: fresh.bars, on: req.db)
            let merged = try await loadCachedHistory(symbol: symbol, from: fromDate, to: toDate, on: req.db)

            let responseBars = merged.isEmpty
                ? fresh.bars.map { makePriceHistoryModel(symbol: symbol, from: $0) }
                : merged
            let response = HistoryResponse(
                symbol: symbol,
                currency: fresh.currency,
                bars: responseBars.map(makePriceBarResponse)
            )
            await redisSetValue(redisKey, value: response, ttlSeconds: cacheConfig.historyTTLSeconds, on: req)
            return response
        } catch {
            if !cachedBars.isEmpty {
                req.logger.warning("market.history stale fallback symbol=\(symbol) provider=\(provider.name)")
                let response = HistoryResponse(
                    symbol: symbol,
                    currency: cacheConfig.defaultCurrency,
                    bars: cachedBars.map(makePriceBarResponse)
                )
                await redisSetValue(redisKey, value: response, ttlSeconds: cacheConfig.historyTTLSeconds, on: req)
                return response
            }
            throw mapProviderError(error, operation: "history")
        }
    }

    func archivedHistory(symbol rawSymbol: String, from rawFrom: String?, to rawTo: String?, on req: Request) async throws -> HistoryResponse {
        let symbol = try normalizeSymbol(rawSymbol)
        let (fromDate, toDate) = try parseHistoryRange(from: rawFrom, to: rawTo)
        let cachedBars = try await loadCachedHistory(symbol: symbol, from: fromDate, to: toDate, on: req.db)

        return HistoryResponse(
            symbol: symbol,
            currency: cacheConfig.defaultCurrency,
            bars: cachedBars.map(makePriceBarResponse)
        )
    }

    func refreshHistory(symbol rawSymbol: String, from rawFrom: String?, to rawTo: String?, on req: Request) async throws -> HistoryResponse {
        let symbol = try normalizeSymbol(rawSymbol)
        let (fromDate, toDate) = try parseHistoryRange(from: rawFrom, to: rawTo)
        let fresh = try await provider.history(symbol: symbol, from: fromDate, to: toDate, on: req)

        try await upsertHistoryBars(symbol: symbol, bars: fresh.bars, on: req.db)
        let archivedBars = try await loadCachedHistory(symbol: symbol, from: fromDate, to: toDate, on: req.db)
        let responseBars = archivedBars.isEmpty
            ? fresh.bars.map { makePriceHistoryModel(symbol: symbol, from: $0) }
            : archivedBars

        return HistoryResponse(
            symbol: symbol,
            currency: fresh.currency,
            bars: responseBars.map(makePriceBarResponse)
        )
    }

    func search(query rawQuery: String, on req: Request) async throws -> [SearchResultResponse] {
        let query = try normalizeQuery(rawQuery)
        let now = Date()
        let providerName = provider.name
        let redisKey = makeSearchRedisKey(provider: providerName, query: query)

        if let hotCached: [SearchResultResponse] = await redisGetValue(redisKey, as: [SearchResultResponse].self, on: req) {
            return hotCached
        }

        let existing = try await SearchCache.query(on: req.db)
            .filter(\.$provider == providerName)
            .filter(\.$normalizedQuery == query)
            .first()

        if let existing,
           isFresh(existing.updatedAt ?? existing.createdAt, ttlSeconds: cacheConfig.searchTTLSeconds, now: now),
           let cachedResults = decodeSearchPayload(existing.payload)
        {
            await redisSetValue(redisKey, value: cachedResults, ttlSeconds: cacheConfig.searchTTLSeconds, on: req)
            return cachedResults
        }

        do {
            let fresh = try await provider.search(query: query, on: req)
            let mapped = fresh.map {
                SearchResultResponse(
                    symbol: $0.symbol,
                    name: $0.name,
                    exchange: $0.exchange,
                    currency: $0.currency,
                    conid: $0.conid
                )
            }

            let payload = try JSONEncoder().encode(mapped)
            let payloadString = String(decoding: payload, as: UTF8.self)
            _ = try await upsertSearchCache(
                query: query,
                provider: providerName,
                payload: payloadString,
                on: req.db
            )
            await redisSetValue(redisKey, value: mapped, ttlSeconds: cacheConfig.searchTTLSeconds, on: req)
            return mapped
        } catch {
            if let existing, let cachedResults = decodeSearchPayload(existing.payload) {
                req.logger.warning("market.search stale fallback query=\(query) provider=\(providerName)")
                await redisSetValue(redisKey, value: cachedResults, ttlSeconds: cacheConfig.searchTTLSeconds, on: req)
                return cachedResults
            }
            throw mapProviderError(error, operation: "search")
        }
    }

    func fx(pair rawPair: String, on req: Request) async throws -> FxRateResponse {
        let (base, quote) = try normalizePair(rawPair)
        let now = Date()
        let redisKey = makeFxRedisKey(provider: provider.name, base: base, quote: quote)

        if let hotCached: FxRateResponse = await redisGetValue(redisKey, as: FxRateResponse.self, on: req) {
            return hotCached
        }

        let existing = try await FxRate.query(on: req.db)
            .filter(\.$base == base)
            .filter(\.$quote == quote)
            .sort(\.$date, .descending)
            .first()

        if let existing, isFresh(existing.date, ttlSeconds: cacheConfig.fxTTLSeconds, now: now) {
            let response = makeFxResponse(from: existing)
            await redisSetValue(redisKey, value: response, ttlSeconds: cacheConfig.fxTTLSeconds, on: req)
            return response
        }

        do {
            let fresh = try await provider.fx(base: base, quote: quote, on: req)
            let cached = try await upsertFxRate(fresh, on: req.db)
            let response = makeFxResponse(from: cached)
            await redisSetValue(redisKey, value: response, ttlSeconds: cacheConfig.fxTTLSeconds, on: req)
            return response
        } catch {
            if let existing {
                req.logger.warning("market.fx stale fallback pair=\(base)\(quote) provider=\(provider.name)")
                let response = makeFxResponse(from: existing)
                await redisSetValue(redisKey, value: response, ttlSeconds: cacheConfig.fxTTLSeconds, on: req)
                return response
            }
            throw mapProviderError(error, operation: "fx")
        }
    }

    func profile(symbol rawSymbol: String, on req: Request) async throws -> CompanyProfileResponse {
        let symbol = try normalizeSymbol(rawSymbol)
        let now = Date()
        let providerName = provider.name
        let redisKey = makeProfileRedisKey(provider: providerName, symbol: symbol)

        if let hotCached: CompanyProfileResponse = await redisGetValue(redisKey, as: CompanyProfileResponse.self, on: req) {
            return hotCached
        }

        let existing = try await ProfileCache.query(on: req.db)
            .filter(\.$provider == providerName)
            .filter(\.$symbol == symbol)
            .first()

        if let existing, isFresh(existing.updatedAt ?? existing.createdAt ?? .distantPast, ttlSeconds: cacheConfig.profileTTLSeconds, now: now) {
            let response = makeProfileResponse(from: existing)
            await redisSetValue(redisKey, value: response, ttlSeconds: cacheConfig.profileTTLSeconds, on: req)
            return response
        }

        do {
            guard let fresh = try await provider.profile(symbol: symbol, on: req) else {
                throw Abort(.notFound, reason: "Profile not found for \(symbol).")
            }
            let cached = try await upsertProfileCache(fresh, provider: providerName, on: req.db)
            let response = makeProfileResponse(from: cached)
            await redisSetValue(redisKey, value: response, ttlSeconds: cacheConfig.profileTTLSeconds, on: req)
            return response
        } catch {
            if let existing {
                req.logger.warning("market.profile stale fallback symbol=\(symbol) provider=\(providerName)")
                let response = makeProfileResponse(from: existing)
                await redisSetValue(redisKey, value: response, ttlSeconds: cacheConfig.profileTTLSeconds, on: req)
                return response
            }
            throw mapProviderError(error, operation: "profile")
        }
    }
}

private extension DefaultMarketDataService {
    func upsertQuoteCache(
        _ quote: MarketProviderQuote,
        provider providerName: String,
        on db: any Database
    ) async throws -> QuoteCache {
        if let existing = try await QuoteCache.query(on: db)
            .filter(\.$provider == providerName)
            .filter(\.$symbol == quote.symbol)
            .first()
        {
            existing.price = quote.price
            existing.currency = quote.currency
            existing.asOf = quote.asOf
            existing.change = quote.change
            existing.percentChange = quote.percentChange
            existing.high = quote.high
            existing.low = quote.low
            existing.open = quote.open
            existing.previousClose = quote.previousClose
            try await existing.save(on: db)
            return existing
        }

        let row = QuoteCache(
            provider: providerName,
            symbol: quote.symbol,
            currency: quote.currency,
            price: quote.price,
            asOf: quote.asOf,
            change: quote.change,
            percentChange: quote.percentChange,
            high: quote.high,
            low: quote.low,
            open: quote.open,
            previousClose: quote.previousClose
        )
        try await row.save(on: db)
        return row
    }

    func upsertSearchCache(
        query: String,
        provider providerName: String,
        payload: String,
        on db: any Database
    ) async throws -> SearchCache {
        if let existing = try await SearchCache.query(on: db)
            .filter(\.$provider == providerName)
            .filter(\.$normalizedQuery == query)
            .first()
        {
            existing.payload = payload
            try await existing.save(on: db)
            return existing
        }

        let row = SearchCache(provider: providerName, normalizedQuery: query, payload: payload)
        try await row.save(on: db)
        return row
    }

    func upsertHistoryBars(
        symbol: String,
        bars: [MarketProviderPriceBar],
        on db: any Database
    ) async throws {
        for bar in bars {
            let day = startOfDay(bar.date)
            if let existing = try await PriceHistory.query(on: db)
                .filter(\.$symbol == symbol)
                .filter(\.$date == day)
                .first()
            {
                existing.open = bar.open
                existing.high = bar.high
                existing.low = bar.low
                existing.close = bar.close
                existing.volume = bar.volume
                try await existing.save(on: db)
                continue
            }

            let model = PriceHistory(
                symbol: symbol,
                date: day,
                open: bar.open,
                high: bar.high,
                low: bar.low,
                close: bar.close,
                volume: bar.volume
            )
            try await model.save(on: db)
        }
    }

    func upsertFxRate(_ rate: MarketProviderFxRate, on db: any Database) async throws -> FxRate {
        let day = startOfDay(rate.asOf)
        if let existing = try await FxRate.query(on: db)
            .filter(\.$date == day)
            .filter(\.$base == rate.base)
            .filter(\.$quote == rate.quote)
            .first()
        {
            existing.rate = rate.rate
            try await existing.save(on: db)
            return existing
        }

        let model = FxRate(
            date: day,
            base: rate.base,
            quote: rate.quote,
            rate: rate.rate
        )
        try await model.save(on: db)
        return model
    }

    func upsertProfileCache(
        _ profile: MarketProviderCompanyProfile,
        provider providerName: String,
        on db: any Database
    ) async throws -> ProfileCache {
        if let existing = try await ProfileCache.query(on: db)
            .filter(\.$provider == providerName)
            .filter(\.$symbol == profile.symbol)
            .first()
        {
            existing.country = profile.country
            existing.currency = profile.currency
            existing.estimateCurrency = profile.estimateCurrency
            existing.exchange = profile.exchange
            existing.finnhubIndustry = profile.finnhubIndustry
            existing.ipo = profile.ipo
            existing.logo = profile.logo
            existing.marketCapitalization = profile.marketCapitalization
            existing.name = profile.name
            existing.phone = profile.phone
            existing.shareOutstanding = profile.shareOutstanding
            existing.ticker = profile.ticker
            existing.weburl = profile.weburl
            try await existing.save(on: db)
            return existing
        }

        let row = ProfileCache(
            provider: providerName,
            symbol: profile.symbol,
            country: profile.country,
            currency: profile.currency,
            estimateCurrency: profile.estimateCurrency,
            exchange: profile.exchange,
            finnhubIndustry: profile.finnhubIndustry,
            ipo: profile.ipo,
            logo: profile.logo,
            marketCapitalization: profile.marketCapitalization,
            name: profile.name,
            phone: profile.phone,
            shareOutstanding: profile.shareOutstanding,
            ticker: profile.ticker,
            weburl: profile.weburl
        )
        try await row.save(on: db)
        return row
    }

    func loadCachedHistory(
        symbol: String,
        from: Date?,
        to: Date?,
        on db: any Database
    ) async throws -> [PriceHistory] {
        let query = PriceHistory.query(on: db)
            .filter(\.$symbol == symbol)
            .sort(\.$date, .ascending)

        if let from {
            query.filter(\.$date >= startOfDay(from))
        }

        if let to {
            query.filter(\.$date <= startOfDay(to))
        }

        return try await query.all()
    }

    func parseHistoryRange(from rawFrom: String?, to rawTo: String?) throws -> (Date?, Date?) {
        let fromDate = try parseOptionalDateOnly(rawFrom, field: "from")
        let toDate = try parseOptionalDateOnly(rawTo, field: "to")

        if let fromDate, let toDate, fromDate > toDate {
            throw Abort(.badRequest, reason: "`from` must be on or before `to`.")
        }

        return (fromDate, toDate)
    }

    func makeQuoteResponse(from model: QuoteCache) -> QuoteResponse {
        QuoteResponse(
            symbol: model.symbol,
            currency: model.currency,
            c: model.price,
            d: model.change,
            dp: model.percentChange,
            h: model.high,
            l: model.low,
            o: model.open,
            pc: model.previousClose,
            t: Int(model.asOf.timeIntervalSince1970)
        )
    }

    func makeFxResponse(from model: FxRate) -> FxRateResponse {
        FxRateResponse(
            base: model.base,
            quote: model.quote,
            rate: model.rate,
            date: formatISODateOnly(model.date)
        )
    }

    func makeProfileResponse(from model: ProfileCache) -> CompanyProfileResponse {
        CompanyProfileResponse(
            country: model.country,
            currency: model.currency,
            estimateCurrency: model.estimateCurrency,
            exchange: model.exchange,
            finnhubIndustry: model.finnhubIndustry,
            ipo: model.ipo,
            logo: model.logo,
            marketCapitalization: model.marketCapitalization,
            name: model.name,
            phone: model.phone,
            shareOutstanding: model.shareOutstanding,
            ticker: model.ticker,
            weburl: model.weburl
        )
    }

    func makePriceBarResponse(from model: PriceHistory) -> PriceBarResponse {
        PriceBarResponse(
            date: formatISODateOnly(model.date),
            open: model.open,
            high: model.high,
            low: model.low,
            close: model.close,
            volume: model.volume
        )
    }

    func makePriceHistoryModel(symbol: String, from bar: MarketProviderPriceBar) -> PriceHistory {
        PriceHistory(
            symbol: symbol,
            date: startOfDay(bar.date),
            open: bar.open,
            high: bar.high,
            low: bar.low,
            close: bar.close,
            volume: bar.volume
        )
    }

    func decodeSearchPayload(_ raw: String) -> [SearchResultResponse]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([SearchResultResponse].self, from: data)
    }

    func makeQuoteRedisKey(provider: String, symbol: String) -> String {
        "market:quote:\(provider):\(symbol)"
    }

    func makeHistoryRedisKey(provider: String, symbol: String, from: Date?, to: Date?) -> String {
        let fromPart = from.map(formatISODateOnly) ?? "none"
        let toPart = to.map(formatISODateOnly) ?? "none"
        return "market:history:\(provider):\(symbol):\(fromPart):\(toPart)"
    }

    func makeSearchRedisKey(provider: String, query: String) -> String {
        "market:search:\(provider):\(query)"
    }

    func makeFxRedisKey(provider: String, base: String, quote: String) -> String {
        "market:fx:\(provider):\(base)\(quote)"
    }

    func makeProfileRedisKey(provider: String, symbol: String) -> String {
        "market:profile:\(provider):\(symbol)"
    }

    func redisGetValue<T: Decodable>(
        _ key: String,
        as type: T.Type,
        on req: Request
    ) async -> T? {
        guard req.application.redis.configuration != nil else {
            return nil
        }

        do {
            guard let data = try await req.redis.get(RedisKey(key), as: Data.self).get() else {
                return nil
            }
            return try JSONDecoder().decode(type, from: data)
        } catch {
            req.logger.warning("market.redis.read failed key=\(key) error=\(error)")
            return nil
        }
    }

    func redisSetValue<T: Encodable>(
        _ key: String,
        value: T,
        ttlSeconds: Int,
        on req: Request
    ) async {
        guard req.application.redis.configuration != nil else {
            return
        }

        do {
            let data = try JSONEncoder().encode(value)
            try await req.redis
                .setex(RedisKey(key), to: data, expirationInSeconds: max(1, ttlSeconds))
                .get()
        } catch {
            req.logger.warning("market.redis.write failed key=\(key) error=\(error)")
        }
    }

    func normalizeSymbol(_ raw: String) throws -> String {
        let symbol = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !symbol.isEmpty else {
            throw Abort(.badRequest, reason: "Symbol is required.")
        }
        return symbol
    }

    func normalizeQuery(_ raw: String) throws -> String {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !query.isEmpty else {
            throw Abort(.badRequest, reason: "Query parameter `q` is required.")
        }
        return query
    }

    func normalizePair(_ raw: String) throws -> (String, String) {
        let compact = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()

        guard compact.count == 6 else {
            throw Abort(.badRequest, reason: "Invalid FX pair. Use `EURUSD` or `EUR/USD`.")
        }

        let base = String(compact.prefix(3))
        let quote = String(compact.suffix(3))
        return (base, quote)
    }

    func parseOptionalDateOnly(_ raw: String?, field: String) throws -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        guard let value = formatter.date(from: trimmed) else {
            throw Abort(.badRequest, reason: "Invalid \(field). Expected YYYY-MM-DD.")
        }
        return startOfDay(value)
    }

    func formatISODateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func formatISODateTime(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    func startOfDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.startOfDay(for: date)
    }

    func isFresh(_ at: Date?, ttlSeconds: Int, now: Date) -> Bool {
        guard let at else { return false }
        return now.timeIntervalSince(at) <= TimeInterval(ttlSeconds)
    }

    func isHistoryFresh(_ history: [PriceHistory], now: Date) -> Bool {
        guard let latest = history.last?.date else { return false }
        return isFresh(latest, ttlSeconds: cacheConfig.historyTTLSeconds, now: now)
    }

    func mapProviderError(_ error: any Error, operation: String) -> any Error {
        if error is MarketDataProviderDisabledError {
            return MarketDataProviderDisabledError()
        }

        if let abort = error as? any AbortError {
            return abort
        }

        return Abort(
            .serviceUnavailable,
            reason: """
                Market provider unavailable for \(operation). Check MARKET_PROVIDER and provider-specific configuration such as FINNHUB_API_KEY or IBKR_API_BASE_URL.
                """
        )
    }
}
