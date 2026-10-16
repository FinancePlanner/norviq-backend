import Foundation
import StockPlanShared

/// Everything the recap deck needs to know about one user and one period.
/// Pure value type, filled by the collector and read by the deck builder
/// and the personality classifier. Every field defaults to zero/empty.
struct RecapFacts: Equatable, Sendable {
    var activeDays: Int = 0
    var activeDaysFirstHalf: Int = 0
    var activeDaysSecondHalf: Int = 0
    var longestStreakDays: Int = 0

    var tradeCount: Int = 0
    var buyCount: Int = 0
    var sellCount: Int = 0
    var tradesBySymbol: [String: Int] = [:]

    /// Watchlist adds, research notes, targets, position memos and stocks added, per symbol.
    var researchTouchesBySymbol: [String: Int] = [:]
    var notesWritten: Int = 0
    var watchlistAdded: Int = 0
    var targetsSet: Int = 0
    var targetsHit: Int = 0

    var growth: [RecapGrowth] = []

    var dividendsReceived: [RecapMoney] = []
    var dividendPayments: Int = 0
    var dividendPayers: Int = 0

    var goalContributions: [RecapMoney] = []
    var goalContributionCount: Int = 0

    var badgesEarned: [RecapBadge] = []
    var xpEarned: Int = 0

    var pilotFollows: Int = 0
    var boardPosts: Int = 0
    var boardComments: Int = 0
    var aiRequests: Int = 0
    var expensesRecorded: Int = 0

    /// For the missed-you slide.
    var bestStreakEverDays: Int = 0
    var totalBadgesEver: Int = 0

    /// True if the user did anything countable in the period.
    var hasAnyActivity: Bool {
        let counts = [
            activeDays, tradeCount, notesWritten, watchlistAdded, targetsSet, targetsHit,
            dividendPayments, goalContributionCount, xpEarned, pilotFollows,
            boardPosts, boardComments, aiRequests, expensesRecorded,
        ]
        return counts.contains { $0 > 0 }
            || !badgesEarned.isEmpty
            || !researchTouchesBySymbol.isEmpty
    }
}
