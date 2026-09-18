import Foundation
import Vapor

/// The public ticker page's earnings teaser.
///
/// `/v1/market/earnings/{symbol}` is gated on the `earningsText` entitlement,
/// which makes the page's earnings table depend on the token owner holding a
/// paid subscription. This is the un-gated slice of the same data: the last few
/// reported quarters and the next scheduled one, with no transcript text.
///
/// It is a separate route rather than a relaxation of the existing one, so the
/// premium gate on `/v1/market/earnings/{symbol}` and on the transcript route
/// stays exactly where it is.
enum RecentEarnings {
    /// How many reported quarters the teaser returns. Four is one fiscal year,
    /// which is what the page's table shows.
    static let reportedQuarterCount = 4

    static func redisKey(symbol: String) -> String {
        "market:earnings-recent:fmp:\(symbol)"
    }

    /// Picks the teaser's rows out of a symbol's earnings history.
    ///
    /// `history` must already carry its streaks — pass it through
    /// `EarningsStreak.annotate` first. Annotating the *whole* history before
    /// slicing is the point: a run longer than `reportedQuarterCount` would
    /// otherwise be silently truncated, and the teaser promises the same
    /// numbers the full earnings route reports.
    static func build(symbol: String, history: [EarningsResponse]) -> RecentEarningsResponse {
        let newestFirst = history.sorted { $0.date > $1.date }
        let reported = newestFirst.filter(EarningsStreak.isReported)

        // The next scheduled quarter is the earliest un-reported row that is
        // newer than the last report. Rows older than that are gaps in the
        // history — a quarter the provider never filled an estimate in for —
        // not a date to put on the page.
        let newestReportedDate = reported.first?.date
        let scheduled = newestFirst.last { row in
            guard !EarningsStreak.isReported(row) else { return false }
            guard let newestReportedDate else { return true }
            return row.date > newestReportedDate
        }

        return RecentEarningsResponse(
            symbol: symbol,
            quarters: reported.prefix(reportedQuarterCount).map { quarter($0, status: .reported) },
            nextScheduled: scheduled.map { quarter($0, status: .scheduled) }
        )
    }

    private static func quarter(
        _ row: EarningsResponse,
        status: RecentEarningsQuarterStatus
    ) -> RecentEarningsQuarter {
        RecentEarningsQuarter(
            date: row.date,
            epsEstimated: row.epsEstimated,
            epsActual: row.epsActual,
            surprisePercent: row.surprisePercent,
            hasTranscript: row.hasTranscript,
            beatStreak: row.beatStreak,
            missStreak: row.missStreak,
            status: status
        )
    }
}

/// Default keeps pre-existing MarketDataService conformers (test stubs)
/// compiling; DefaultMarketDataService overrides with the real assembly.
extension MarketDataService {
    func recentEarnings(symbol _: String, on _: Request) async throws -> RecentEarningsResponse {
        throw Abort(.serviceUnavailable, reason: "Recent earnings are not supported by this provider.")
    }
}

extension DefaultMarketDataService {
    func recentEarnings(symbol rawSymbol: String, on req: Request) async throws -> RecentEarningsResponse {
        let symbol = try normalizeSymbol(rawSymbol)
        let cacheKey = RecentEarnings.redisKey(symbol: symbol)

        if let cached = await redisGetValue(cacheKey, as: RecentEarningsResponse.self, on: req) {
            return cached
        }

        // The same fetch and the same streak derivation the Pro-gated route
        // uses, reused rather than reimplemented. `limit: nil` matches that
        // route's default, so both see the same history.
        let history = try await EarningsStreak.annotate(
            earnings(symbol: symbol, limit: nil, on: req)
        )
        let response = RecentEarnings.build(symbol: symbol, history: history)

        await redisSetValue(
            cacheKey,
            value: response,
            ttlSeconds: cacheConfig.recentEarningsTTLSeconds,
            on: req
        )
        return response
    }
}
