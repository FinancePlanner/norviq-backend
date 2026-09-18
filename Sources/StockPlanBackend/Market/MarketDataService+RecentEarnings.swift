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

    /// Today in UTC as `YYYY-MM-DD`, in the same shape the provider dates its
    /// quarters, so the two compare lexicographically.
    static func today(_ now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    /// Picks the teaser's rows out of a symbol's earnings history.
    ///
    /// `history` must already carry its streaks — pass it through
    /// `EarningsStreak.annotate` first. Annotating the *whole* history before
    /// slicing is the point: a run longer than `reportedQuarterCount` would
    /// otherwise be silently truncated, and the teaser promises the same
    /// numbers the full earnings route reports.
    /// `today` (UTC, `YYYY-MM-DD`) is only consulted for a symbol with no
    /// reported quarter at all; see below.
    static func build(
        symbol: String,
        history: [EarningsResponse],
        today: String = RecentEarnings.today()
    ) -> RecentEarningsResponse {
        let newestFirst = history.sorted { $0.date > $1.date }
        let reported = newestFirst.filter(EarningsStreak.isReported)

        // The next scheduled quarter is the *earliest* un-reported row after the
        // last report — `newestFirst.last(where:)` is that earliest match. Rows
        // before the last report are gaps in the history (a quarter the provider
        // never filled an estimate in for), not a date to put on the page.
        //
        // The date of the last report is deliberately the only floor when there
        // is one: providers routinely leave a scheduled date in place for days
        // after it passes, and the page's next-report line should still show it.
        // With no reported quarter to anchor to — a newly listed company —
        // every un-reported row would otherwise qualify and the *oldest* one in
        // the whole history would win, which can be years in the past. There,
        // and only there, "next" falls back to meaning "not before today".
        let newestReportedDate = reported.first?.date
        let scheduled = newestFirst.last { row in
            guard !EarningsStreak.isReported(row) else { return false }
            guard let newestReportedDate else { return row.date >= today }
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

        // Worth noting for whoever tunes this: a miss costs two upstream calls,
        // not one — `earnings` fetches the history and the provider's transcript
        // *availability* list to fill `hasTranscript`. An empty answer is cached
        // like any other, for an hour, which is strictly shorter than the day
        // `earnings()` already pins its own empty payload for.
        await redisSetValue(
            cacheKey,
            value: response,
            ttlSeconds: cacheConfig.recentEarningsTTLSeconds,
            on: req
        )
        return response
    }
}
