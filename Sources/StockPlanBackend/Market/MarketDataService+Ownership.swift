import Foundation
import Vapor

/// Insider filings, congressional disclosures and 13F institutional ownership.
///
/// The three share a cache TTL (`MARKET_TTL_OWNERSHIP_SECONDS`) because they
/// share an update cadence: all three are driven by filings, none of which
/// arrive more than a few times a day.
///
/// Defaults keep pre-existing MarketDataService conformers (test stubs)
/// compiling; DefaultMarketDataService overrides with the real assembly.
extension MarketDataService {
    func insiderActivity(
        symbol _: String,
        windowDays _: Int,
        on _: Request
    ) async throws -> InsiderActivityResponse {
        throw Abort(.serviceUnavailable, reason: "Insider activity is not supported by this provider.")
    }

    func congressTrades(symbol _: String, on _: Request) async throws -> CongressTradesResponse {
        throw Abort(.serviceUnavailable, reason: "Congressional trades are not supported by this provider.")
    }

    func recentCongressTrades(limit _: Int, on _: Request) async throws -> CongressTradesResponse {
        throw Abort(.serviceUnavailable, reason: "Congressional trades are not supported by this provider.")
    }

    func institutionalOwnership(symbol _: String, on _: Request) async throws -> InstitutionalOwnershipResponse {
        throw Abort(.serviceUnavailable, reason: "Institutional ownership is not supported by this provider.")
    }
}

/// Rows from one upstream call, plus whether that call degraded.
///
/// `degraded` exists so a degraded answer is not written to Redis: an FMP plan
/// that momentarily 502s would otherwise pin an empty response for the whole
/// TTL.
/// Which congressional feed a chamber is being asked for.
private enum CongressQuery {
    /// Every disclosure this chamber filed for one symbol.
    case symbol(String)
    /// The chamber's most recent disclosures across all symbols.
    case latest(Int)
}

private struct OwnershipFetch<Row> {
    let rows: [Row]
    let degraded: Bool

    static func loaded(_ rows: [Row]) -> Self {
        .init(rows: rows, degraded: false)
    }

    static var empty: Self {
        .init(rows: [], degraded: true)
    }
}

extension DefaultMarketDataService {
    // MARK: - Insider activity

    func insiderActivity(
        symbol rawSymbol: String,
        windowDays requestedWindow: Int,
        on req: Request
    ) async throws -> InsiderActivityResponse {
        let symbol = try normalizeSymbol(rawSymbol)
        let windowDays = InsiderActivityConfig.clampWindowDays(requestedWindow)
        let cacheKey = InsiderActivityConfig.redisKey(symbol: symbol, windowDays: windowDays)

        if let cached = await redisGetValue(cacheKey, as: InsiderActivityResponse.self, on: req) {
            return cached
        }
        guard let fmp = fmpProvider else {
            throw Abort(.serviceUnavailable, reason: "Insider activity requires the FMP provider.")
        }

        let fetched = try await loadInsiderPages(fmp: fmp, symbol: symbol, windowDays: windowDays, on: req)
        let response = InsiderActivity.build(symbol: symbol, windowDays: windowDays, wire: fetched.rows)

        if !fetched.degraded {
            await redisSetValue(cacheKey, value: response, ttlSeconds: cacheConfig.ownershipTTLSeconds, on: req)
        }
        return response
    }

    /// Walks the insider search endpoint until the window is covered or the row
    /// ceiling is reached, whichever comes first.
    ///
    /// Rows arrive newest first, so a page whose oldest row predates the window
    /// is the last page worth asking for. Pages already collected are kept when
    /// a later page degrades — a partial window beats none.
    private func loadInsiderPages(
        fmp: any FMPMarketDataProvider,
        symbol: String,
        windowDays: Int,
        on req: Request
    ) async throws -> OwnershipFetch<FMPInsiderTrade> {
        let cutoff = InsiderActivity.cutoffDay(windowDays: windowDays)
        var rows: [FMPInsiderTrade] = []
        var page = 0

        while rows.count < InsiderActivityConfig.maxRows {
            let batch: [FMPInsiderTrade]
            do {
                batch = try await fmp.fetchInsiderTrades(
                    symbol: symbol,
                    page: page,
                    limit: InsiderActivityConfig.pageSize,
                    on: req
                )
            } catch let error where MarketDataDegradation.isMissingData(error) {
                MarketDataDegradation.warnOnce(feature: "market.insider", error: error, logger: req.logger)
                return OwnershipFetch(rows: rows, degraded: true)
            }

            guard !batch.isEmpty else { break }
            rows.append(contentsOf: batch)

            if batch.count < InsiderActivityConfig.pageSize {
                break
            }
            if let oldest = batch.compactMap(\.transactionDate).min(), oldest < cutoff {
                break
            }
            page += 1
        }
        return .loaded(Array(rows.prefix(InsiderActivityConfig.maxRows)))
    }

    // MARK: - Congressional trades

    func congressTrades(symbol rawSymbol: String, on req: Request) async throws -> CongressTradesResponse {
        let symbol = try normalizeSymbol(rawSymbol)
        let cacheKey = CongressTradesConfig.redisKey(symbol: symbol)

        if let cached = await redisGetValue(cacheKey, as: CongressTradesResponse.self, on: req) {
            return cached
        }
        guard let fmp = fmpProvider else {
            throw Abort(.serviceUnavailable, reason: "Congressional trades require the FMP provider.")
        }

        async let senateTask = loadCongressTrades(fmp: fmp, chamber: .senate, query: .symbol(symbol), on: req)
        async let houseTask = loadCongressTrades(fmp: fmp, chamber: .house, query: .symbol(symbol), on: req)
        let senate = try await senateTask
        let house = try await houseTask

        let response = CongressTradesResponse(trades: CongressTrades.merge(senate.rows, house.rows))
        if !senate.degraded, !house.degraded {
            await redisSetValue(cacheKey, value: response, ttlSeconds: cacheConfig.ownershipTTLSeconds, on: req)
        }
        return response
    }

    func recentCongressTrades(limit requestedLimit: Int, on req: Request) async throws -> CongressTradesResponse {
        let limit = CongressTradesConfig.clampRecentLimit(requestedLimit)
        let cacheKey = CongressTradesConfig.recentRedisKey(limit: limit)

        if let cached = await redisGetValue(cacheKey, as: CongressTradesResponse.self, on: req) {
            return cached
        }
        guard let fmp = fmpProvider else {
            throw Abort(.serviceUnavailable, reason: "Congressional trades require the FMP provider.")
        }

        // Each chamber is asked for the full limit; the merged list is then cut
        // back to it, so a quiet chamber does not cost the caller rows.
        async let senateTask = loadCongressTrades(fmp: fmp, chamber: .senate, query: .latest(limit), on: req)
        async let houseTask = loadCongressTrades(fmp: fmp, chamber: .house, query: .latest(limit), on: req)
        let senate = try await senateTask
        let house = try await houseTask

        let merged = CongressTrades.merge(senate.rows, house.rows)
        let response = CongressTradesResponse(trades: Array(merged.prefix(limit)))
        if !senate.degraded, !house.degraded {
            await redisSetValue(cacheKey, value: response, ttlSeconds: cacheConfig.ownershipTTLSeconds, on: req)
        }
        return response
    }

    /// One chamber's disclosures.
    private func loadCongressTrades(
        fmp: any FMPMarketDataProvider,
        chamber: CongressChamber,
        query: CongressQuery,
        on req: Request
    ) async throws -> OwnershipFetch<CongressTrade> {
        do {
            let wire: [FMPCongressTrade] = switch (chamber, query) {
            case let (.senate, .symbol(symbol)):
                try await fmp.senateTrades(symbol: symbol, on: req)
            case let (.house, .symbol(symbol)):
                try await fmp.houseTrades(symbol: symbol, on: req)
            case let (.senate, .latest(limit)):
                try await fmp.latestSenateTrades(limit: limit, on: req)
            case let (.house, .latest(limit)):
                try await fmp.latestHouseTrades(limit: limit, on: req)
            }
            return .loaded(wire.compactMap { CongressTrades.trade(from: $0, chamber: chamber) })
        } catch let error where MarketDataDegradation.isMissingData(error) {
            MarketDataDegradation.warnOnce(
                feature: "market.congress.\(chamber.rawValue)",
                error: error,
                logger: req.logger
            )
            return .empty
        }
    }

    // MARK: - Institutional ownership

    func institutionalOwnership(symbol rawSymbol: String, on req: Request) async throws
        -> InstitutionalOwnershipResponse
    {
        let symbol = try normalizeSymbol(rawSymbol)
        let cacheKey = InstitutionalOwnership.redisKey(symbol)

        if let cached = await redisGetValue(cacheKey, as: InstitutionalOwnershipResponse.self, on: req) {
            return cached
        }
        guard let fmp = fmpProvider else {
            throw Abort(.serviceUnavailable, reason: "Institutional ownership requires the FMP provider.")
        }

        // 13Fs are due 45 days after a quarter closes, so the most recent
        // quarter is often still empty. One step back covers that gap.
        var quarter = MarketQuarter.latestReported()
        var holders = try await loadInstitutionalHolders(fmp: fmp, symbol: symbol, quarter: quarter, on: req)
        if holders.rows.isEmpty, !holders.degraded {
            quarter = quarter.previous()
            holders = try await loadInstitutionalHolders(fmp: fmp, symbol: symbol, quarter: quarter, on: req)
        }

        let summary = try await loadInstitutionalSummary(fmp: fmp, symbol: symbol, quarter: quarter, on: req)
        let response = InstitutionalOwnership.build(
            symbol: symbol,
            quarter: quarter,
            wireHolders: holders.rows,
            summary: summary.rows.first
        )

        if !holders.degraded, !summary.degraded {
            await redisSetValue(cacheKey, value: response, ttlSeconds: cacheConfig.ownershipTTLSeconds, on: req)
        }
        return response
    }

    private func loadInstitutionalHolders(
        fmp: any FMPMarketDataProvider,
        symbol: String,
        quarter: MarketQuarter,
        on req: Request
    ) async throws -> OwnershipFetch<FMPInstitutionalHolder> {
        do {
            let rows = try await fmp.institutionalHolders(
                symbol: symbol,
                year: quarter.year,
                quarter: quarter.quarter,
                on: req
            )
            return .loaded(rows)
        } catch let error where MarketDataDegradation.isMissingData(error) {
            MarketDataDegradation.warnOnce(feature: "market.institutional.holders", error: error, logger: req.logger)
            return .empty
        }
    }

    private func loadInstitutionalSummary(
        fmp: any FMPMarketDataProvider,
        symbol: String,
        quarter: MarketQuarter,
        on req: Request
    ) async throws -> OwnershipFetch<FMPInstitutionalPositionsSummary> {
        do {
            let rows = try await fmp.institutionalPositionsSummary(
                symbol: symbol,
                year: quarter.year,
                quarter: quarter.quarter,
                on: req
            )
            return .loaded(rows)
        } catch let error where MarketDataDegradation.isMissingData(error) {
            MarketDataDegradation.warnOnce(feature: "market.institutional.summary", error: error, logger: req.logger)
            return .empty
        }
    }
}
