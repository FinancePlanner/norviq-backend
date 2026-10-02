import Foundation
import NIOConcurrencyHelpers
import StockPlanShared
import Vapor

protocol CryptoMarketsService: Sendable {
    func markets(timeframe: CryptoMarketsTimeframe, limit: Int, on req: Request) async throws -> CryptoMarketsResponse
    /// Fetches a fresh universe, enriches it and writes it to every cache tier.
    /// `ytdFillBudget` caps the FMP history calls spent on missing YTD bases.
    @discardableResult
    func refreshSnapshot(ytdFillBudget: Int, on req: Request) async throws -> CryptoMarketSnapshot
}

/// Serves `/v1/crypto/markets` from a snapshot the refresh job keeps warm.
///
/// Read path: in-process copy → Redis fresh key → inline refresh (single
/// flight) → Redis stale key, flagged `isStale` → 502. The stale key outlives
/// the fresh one by a day, so a CoinGecko outage or exhausted quota degrades
/// to old numbers, not an error.
final class DefaultCryptoMarketsService: CryptoMarketsService, @unchecked Sendable {
    enum Keys {
        static let snapshot = "crypto:markets:snapshot:v1"
        static let staleSnapshot = "crypto:markets:snapshot:v1:stale"
        static let excludedIds = "crypto:markets:excluded-ids:v1"
        static let fmpSymbols = "crypto:fmp-symbols:v1"
        static func ytdBases(year: Int) -> String {
            "crypto:markets:ytd-base:v1:\(year)"
        }

        /// Present while YTD filling is paused after an FMP failure.
        static let ytdFillPaused = "crypto:markets:ytd-fill-paused:v1"
    }

    static let staleTTLSeconds = 86400
    /// How long a pod trusts its in-process copy before re-reading Redis, so
    /// replicas that do not run the refresh job pick up new snapshots promptly.
    static let memoryTTL: TimeInterval = 60
    /// After a failed inline refresh, serve stale data for this long instead
    /// of retrying upstream on every request.
    static let inlineRetryBackoff: TimeInterval = 60
    static let dailyTTLSeconds = 86400
    static let ytdBaseTTLSeconds = 400 * 86400
    /// After any FMP failure (in practice the plan's call quota: "Limit
    /// Reach"), stop asking for YTD bases this long. FMP's key is shared with
    /// stock quotes and news, so retrying every tick throttles those too.
    static let ytdFillPauseSeconds = 6 * 3600

    private let provider: any CryptoMarketsProvider
    private let reference: (any CryptoReferenceDataSource)?
    private let cache: any AIResponseCache
    private let filter: CryptoMarketsFilter
    private let universeSize: Int
    /// Only the largest coins get a YTD figure: each base costs one FMP call.
    private let ytdCoverage: Int
    private let freshTTLSeconds: Int
    private let now: @Sendable () -> Date
    private let memory = NIOLockedValueBox<(snapshot: CryptoMarketSnapshot, storedAt: Date)?>(nil)
    private let singleFlight = CryptoSnapshotSingleFlight()
    private let lastInlineFailure = NIOLockedValueBox<Date?>(nil)
    private let ytdFillPausedUntil = NIOLockedValueBox<Date?>(nil)

    init(
        provider: any CryptoMarketsProvider,
        reference: (any CryptoReferenceDataSource)?,
        cache: any AIResponseCache,
        filter: CryptoMarketsFilter = .init(),
        universeSize: Int = 250,
        ytdCoverage: Int = 50,
        freshTTLSeconds: Int,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.reference = reference
        self.cache = cache
        self.filter = filter
        self.universeSize = min(max(universeSize, 10), 250)
        self.ytdCoverage = max(ytdCoverage, 0)
        self.freshTTLSeconds = max(freshTTLSeconds, 60)
        self.now = now
    }

    func markets(timeframe: CryptoMarketsTimeframe, limit: Int, on req: Request) async throws -> CryptoMarketsResponse {
        if let snapshot = await freshSnapshot(on: req) {
            return assemble(snapshot, timeframe: timeframe, limit: limit, isStale: false)
        }
        do {
            if let failedAt = lastInlineFailure.withLockedValue({ $0 }),
               now().timeIntervalSince(failedAt) < Self.inlineRetryBackoff
            {
                throw Abort(.serviceUnavailable, reason: "Crypto markets upstream recently failed.")
            }
            let snapshot = try await singleFlight.run {
                try await self.refreshSnapshot(ytdFillBudget: 0, on: req)
            }
            lastInlineFailure.withLockedValue { $0 = nil }
            return assemble(snapshot, timeframe: timeframe, limit: limit, isStale: false)
        } catch {
            if (error as? Abort)?.status != .serviceUnavailable {
                lastInlineFailure.withLockedValue { $0 = now() }
            }
            req.logger.warning("crypto_markets inline refresh failed error=\(error)")
            let stale: CryptoMarketSnapshot? = if let cached = memory.withLockedValue({ $0?.snapshot }) {
                cached
            } else {
                await cache.get(Keys.staleSnapshot, on: req)
            }
            guard let stale else {
                throw Abort(.badGateway, reason: "Crypto market data isn’t available right now. Please try again later.")
            }
            return assemble(stale, timeframe: timeframe, limit: limit, isStale: true)
        }
    }

    @discardableResult
    func refreshSnapshot(ytdFillBudget: Int, on req: Request) async throws -> CryptoMarketSnapshot {
        let universe = try await provider.fetchUniverse(limit: universeSize, on: req)
        guard !universe.isEmpty else {
            throw Abort(.badGateway, reason: "Crypto market data provider returned no coins.")
        }

        let excluded = await excludedIds(on: req)
        let knownFMP = await fmpSymbols(on: req)

        var seenSymbols = Set<String>()
        var coins: [CryptoMarketCoin] = []
        for coin in universe.sorted(by: { ($0.marketCap ?? 0) > ($1.marketCap ?? 0) }) {
            guard !excluded.contains(coin.id), !Self.looksPegged(coin) else { continue }
            // Tickers are not unique; the larger coin keeps the symbol.
            guard seenSymbols.insert(coin.symbol).inserted else { continue }
            let fmpSymbol = "\(coin.symbol)USD"
            coins.append(coin.replacing(
                fmpSymbol: .some(knownFMP.contains(fmpSymbol) ? fmpSymbol : nil),
                sector: CryptoSectorMap.sector(for: coin.id)
            ))
        }

        coins = await applyYearToDate(coins, fillBudget: ytdFillBudget, on: req)

        let total = universe.compactMap(\.marketCap).reduce(0, +)
        let bitcoinCap = universe.first(where: { $0.id == "bitcoin" })?.marketCap
        let snapshot = CryptoMarketSnapshot(
            source: provider.name,
            attribution: provider.attribution,
            asOf: ISO8601DateFormatter().string(from: now()),
            totalMarketCap: total > 0 ? total : nil,
            btcDominancePct: bitcoinCap.flatMap { total > 0 ? $0 / total * 100 : nil },
            coins: coins
        )

        memory.withLockedValue { $0 = (snapshot, now()) }
        await cache.set(Keys.snapshot, value: snapshot, ttlSeconds: freshTTLSeconds, on: req)
        await cache.set(Keys.staleSnapshot, value: snapshot, ttlSeconds: Self.staleTTLSeconds, on: req)
        return snapshot
    }

    // MARK: - Internals

    private func assemble(
        _ snapshot: CryptoMarketSnapshot,
        timeframe: CryptoMarketsTimeframe,
        limit: Int,
        isStale: Bool
    ) -> CryptoMarketsResponse {
        CryptoMarketsAssembler.assemble(
            snapshot: snapshot, timeframe: timeframe, limit: limit,
            isStale: isStale, filter: filter, now: now()
        )
    }

    private func freshSnapshot(on req: Request) async -> CryptoMarketSnapshot? {
        if let entry = memory.withLockedValue({ $0 }),
           now().timeIntervalSince(entry.storedAt) < Self.memoryTTL
        {
            return entry.snapshot
        }
        // Another replica (or a previous pod) may have refreshed already.
        guard let shared: CryptoMarketSnapshot = await cache.get(Keys.snapshot, on: req) else { return nil }
        memory.withLockedValue { $0 = (shared, now()) }
        return shared
    }

    private func excludedIds(on req: Request) async -> Set<String> {
        if let cached: [String] = await cache.get(Keys.excludedIds, on: req) {
            return Set(cached).union(CryptoSectorMap.fallbackExcludedIds)
        }
        do {
            let ids = try await provider.fetchExcludedIds(on: req)
            await cache.set(Keys.excludedIds, value: Array(ids), ttlSeconds: Self.dailyTTLSeconds, on: req)
            return ids.union(CryptoSectorMap.fallbackExcludedIds)
        } catch {
            req.logger.warning("crypto_markets excluded-ids fetch failed; using fallback list error=\(error)")
            return CryptoSectorMap.fallbackExcludedIds
        }
    }

    private func fmpSymbols(on req: Request) async -> Set<String> {
        guard let reference else { return [] }
        if let cached: [String] = await cache.get(Keys.fmpSymbols, on: req) {
            return Set(cached)
        }
        do {
            let symbols = try await reference.knownSymbols(on: req)
            await cache.set(Keys.fmpSymbols, value: Array(symbols), ttlSeconds: Self.dailyTTLSeconds, on: req)
            return symbols
        } catch {
            // Without the list no coin links to a detail page; better than
            // linking to pages that 404.
            req.logger.warning("crypto_markets fmp symbol list fetch failed error=\(error)")
            return []
        }
    }

    /// YTD = current price over the last close of the previous year. That base
    /// never changes within a year, so each coin costs one FMP history call per
    /// year; the job fills a few per tick (FMP's basic plan has no batch call
    /// and a small daily quota shared with every other FMP feature). Only the
    /// top `ytdCoverage` coins are filled, and the first failure stops the
    /// batch and pauses filling for `ytdFillPauseSeconds`.
    /// A stored 0 marks "FMP has no history" so the coin is not retried.
    private func applyYearToDate(
        _ coins: [CryptoMarketCoin],
        fillBudget: Int,
        on req: Request
    ) async -> [CryptoMarketCoin] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let year = calendar.component(.year, from: now())
        let key = Keys.ytdBases(year: year)
        var bases: [String: Double] = await cache.get(key, on: req) ?? [:]

        if let reference, fillBudget > 0, await !ytdFillIsPaused(on: req) {
            let missing = coins.prefix(ytdCoverage)
                .compactMap(\.fmpSymbol)
                .filter { bases[$0] == nil }
                .prefix(fillBudget)
            var changed = false
            for symbol in missing {
                if Task.isCancelled {
                    break
                }
                do {
                    bases[symbol] = try await reference.yearStartPrice(symbol: symbol, year: year, on: req) ?? 0
                    changed = true
                } catch {
                    // Not recorded, so the coin is retried after the pause. One
                    // failure is enough: the rest of the batch would hit the
                    // same quota.
                    await pauseYTDFill(on: req)
                    req.logger.warning("crypto_markets ytd fill paused \(Self.ytdFillPauseSeconds)s after failure symbol=\(symbol) error=\(error)")
                    break
                }
            }
            if changed {
                await cache.set(key, value: bases, ttlSeconds: Self.ytdBaseTTLSeconds, on: req)
            }
        }

        return coins.map { coin in
            guard let symbol = coin.fmpSymbol, let base = bases[symbol], base > 0 else { return coin }
            let returns = coin.returns
            return coin.replacing(returns: CryptoTimeframeReturns(
                oneDay: returns.oneDay,
                oneWeek: returns.oneWeek,
                oneMonth: returns.oneMonth,
                yearToDate: (coin.price / base - 1) * 100,
                oneYear: returns.oneYear
            ))
        }
    }

    private func ytdFillIsPaused(on req: Request) async -> Bool {
        if let until = ytdFillPausedUntil.withLockedValue({ $0 }), now() < until {
            return true
        }
        // Shared across replicas and restarts, so a new pod does not spend
        // the quota again straight away.
        let paused: Bool? = await cache.get(Keys.ytdFillPaused, on: req)
        return paused == true
    }

    private func pauseYTDFill(on req: Request) async {
        ytdFillPausedUntil.withLockedValue { $0 = now().addingTimeInterval(TimeInterval(Self.ytdFillPauseSeconds)) }
        await cache.set(Keys.ytdFillPaused, value: true, ttlSeconds: Self.ytdFillPauseSeconds, on: req)
    }

    /// Last-resort stablecoin guard for anything the category call and the
    /// fallback list miss (tokenised money-market funds, new dollar coins).
    static func looksPegged(_ coin: CryptoMarketCoin) -> Bool {
        guard abs(coin.price - 1) < 0.02 else { return false }
        let month = coin.returns.oneMonth ?? coin.returns.oneDay ?? 0
        return abs(month) < 2
    }
}

/// Collapses concurrent cold-cache refreshes into one upstream call.
actor CryptoSnapshotSingleFlight {
    private var inFlight: Task<CryptoMarketSnapshot, any Error>?

    func run(_ operation: @escaping @Sendable () async throws -> CryptoMarketSnapshot) async throws -> CryptoMarketSnapshot {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await operation() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}
