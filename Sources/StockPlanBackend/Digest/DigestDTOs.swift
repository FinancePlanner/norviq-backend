import Foundation
import Vapor

// Backend-local for now: they move to StockPlanShared when iOS starts reading
// them (slice 2), so slice 1 ships without a shared-package tag bump.

/// Everything a digest says, computed before any model sees it. Stored as JSON
/// on `weekly_digests.payload` and rendered into email, push and the app.
struct DigestPayload: Content, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = DigestPayload.currentSchemaVersion
    var periodStart: String
    var periodEnd: String
    /// One entry per portfolio base currency; amounts are never converted.
    var holdings: [DigestCurrencyMove] = []
    /// Positions with a price at both ends of the week, out of `totalPositions`.
    var pricedPositions: Int = 0
    var totalPositions: Int = 0
    var movers: [DigestMover] = []
    var budget: DigestBudget?
    var inflation: DigestInflation?
    /// Latest personal-inflation `asOf` seen, shown or not, so the section
    /// appears once per new month instead of every week.
    var inflationAsOfSeen: String?
    var earnings: [DigestEarning] = []

    var isEmpty: Bool {
        holdings.isEmpty && budget == nil && inflation == nil && earnings.isEmpty
    }
}

struct DigestCurrencyMove: Content, Equatable {
    let currency: String
    let startValue: Double
    let endValue: Double
    let change: Double
    /// Nil when the start value is zero.
    let changePercent: Double?
}

struct DigestMover: Content, Equatable {
    let symbol: String
    let currency: String
    let shares: Double
    let startPrice: Double
    let endPrice: Double
    /// shares × (endPrice − startPrice).
    let contribution: Double
    let changePercent: Double
    /// The model's "why it moved" line (slice 2). Nil in numbers-only digests.
    var why: String?
}

struct DigestBudget: Content, Equatable {
    let monthStart: String
    let currency: String
    let lines: [DigestBudgetLine]
}

struct DigestBudgetLine: Content, Equatable {
    let title: String
    let target: Double
    let actual: Double
    /// actual − target: positive is over budget.
    let drift: Double
    let driftPercent: Double?
}

struct DigestInflation: Content, Equatable {
    let country: String
    let asOf: String
    let personalRate: Double
    let officialRate: Double
}

struct DigestEarning: Content, Equatable {
    let symbol: String
    let date: String
    /// Finnhub's `bmo` / `amc` / `dmh`, when known.
    let hour: String?
}

// MARK: - API

struct DigestPreferencesResponse: Content, Equatable {
    /// False until the user has answered the opt-in card once.
    let decided: Bool
    let emailEnabled: Bool
    let pushEnabled: Bool
    let telegramEnabled: Bool
    let sentimentAlertsEnabled: Bool
    let weekday: Int
    let localHour: Int
    let timezone: String
    let country: String?
}

/// Every field optional: a PUT changes only what it names.
struct DigestPreferencesUpdate: Content {
    var emailEnabled: Bool?
    var pushEnabled: Bool?
    var telegramEnabled: Bool?
    var sentimentAlertsEnabled: Bool?
    var weekday: Int?
    var localHour: Int?
    var timezone: String?
    var country: String?
}

struct DigestSummary: Content, Equatable {
    let id: UUID
    let periodStart: String
    let periodEnd: String
    let status: String
    let headline: String
}

struct DigestListResponse: Content {
    let items: [DigestSummary]
}

struct DigestResponse: Content {
    let id: UUID
    let periodStart: String
    let periodEnd: String
    let status: String
    let headline: String
    let payload: DigestPayload
    let narrative: String?
    let createdAt: Date?
}

struct DigestUnsubscribeResponse: Content {
    let unsubscribed: Bool
}
