import Foundation
import Vapor

/// The earnings teaser served to the public ticker pages at `/s/{SYMBOL}`.
///
/// Deliberately a different shape from `EarningsResponse`: this one is session-
/// auth only, so it carries only what a page open to the internet may show —
/// the recent EPS estimate/actual pairs, their surprise, the beat/miss run, and
/// whether a transcript exists. It never carries transcript text, which stays
/// behind `earningsText` on `/v1/market/earnings/{symbol}/transcript`.
public struct RecentEarningsResponse: Content, Sendable, Equatable {
    public let symbol: String
    /// The most recently *reported* quarters, newest first, at most
    /// `RecentEarnings.reportedQuarterCount` of them.
    ///
    /// Empty means the provider returned no quarter for this symbol with both
    /// an EPS actual and an EPS estimate — a newly listed company, or a symbol
    /// the provider does not cover. It is a real answer, not an error and not a
    /// statement that the company has never reported.
    public let quarters: [RecentEarningsQuarter]
    /// The next quarter the provider lists but has not reported yet. Never one
    /// of `quarters`, so it cannot displace a reported quarter.
    ///
    /// Absent — the JSON key is omitted, not set to null — when the provider
    /// lists no such quarter. A date that has just passed can still appear here:
    /// providers leave a scheduled date in place for a while after it, and the
    /// page's next-report line should still show it. The one exception is a
    /// symbol with nothing reported at all, where there is no last report to
    /// anchor to and only a quarter dated today or later qualifies.
    public let nextScheduled: RecentEarningsQuarter?

    public init(
        symbol: String,
        quarters: [RecentEarningsQuarter],
        nextScheduled: RecentEarningsQuarter?
    ) {
        self.symbol = symbol
        self.quarters = quarters
        self.nextScheduled = nextScheduled
    }
}

/// One quarter of the teaser.
public struct RecentEarningsQuarter: Content, Sendable, Equatable {
    /// The earnings date, `YYYY-MM-DD`.
    public let date: String
    public let epsEstimated: Double?
    /// The EPS the company reported, or `nil` when the provider has not
    /// reported one.
    ///
    /// Usually `nil` on a `scheduled` row, but **not guaranteed**: a quarter is
    /// `scheduled` when *either* side of the comparison is missing, so a row the
    /// provider lists with an actual and no estimate is `scheduled` and carries
    /// that actual. Read `status` for whether the quarter has a comparable
    /// result; do not infer it from this field.
    public let epsActual: Double?
    /// How far the actual came in above (positive) or below (negative) the
    /// estimate, in percent. `nil` when either side is missing or the estimate
    /// is zero.
    public let surprisePercent: Double?
    /// Whether the provider lists an earnings call transcript for this quarter.
    /// An availability flag only — the text is Pro-gated and is never included
    /// in this response.
    public let hasTranscript: Bool
    /// The beat run *ending at this row*: consecutive reported quarters, this
    /// one included, where EPS came in at or above the estimate.
    ///
    /// At most one of `beatStreak` and `missStreak` is non-zero. **Both zero
    /// means this row has no comparable result** — which is the normal state of
    /// a `scheduled` quarter. Both zero does *not* mean the quarter missed; a
    /// miss is `missStreak >= 1`.
    ///
    /// Counted over the symbol's whole earnings history, not just the rows
    /// returned here, so the numbers are the ones
    /// `/v1/market/earnings/{symbol}` reports for the same quarters.
    public let beatStreak: Int
    /// The `beatStreak` counterpart: the miss run ending at this row. Same
    /// invariant — at most one of the two is non-zero, and both zero means this
    /// row carries no comparable result rather than a beat.
    public let missStreak: Int
    /// Whether this row is a result or a date on the calendar.
    public let status: RecentEarningsQuarterStatus

    public init(
        date: String,
        epsEstimated: Double?,
        epsActual: Double?,
        surprisePercent: Double?,
        hasTranscript: Bool,
        beatStreak: Int,
        missStreak: Int,
        status: RecentEarningsQuarterStatus
    ) {
        self.date = date
        self.epsEstimated = epsEstimated
        self.epsActual = epsActual
        self.surprisePercent = surprisePercent
        self.hasTranscript = hasTranscript
        self.beatStreak = beatStreak
        self.missStreak = missStreak
        self.status = status
    }
}

/// Reported or scheduled, said on the row itself so a flattened list stays
/// unambiguous. This — not the nullability of `epsActual` — is the field to
/// branch on.
public enum RecentEarningsQuarterStatus: String, Codable, Sendable, Equatable {
    /// Both an EPS actual and an EPS estimate are present, so the quarter has a
    /// comparable result.
    case reported
    /// The provider lists the quarter but not a result for it yet.
    case scheduled
}
