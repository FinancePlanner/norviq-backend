import Vapor

// MARK: - /v1/market/pressure/:symbol response

/// Buying/selling-pressure snapshot for one symbol: relative trading volume,
/// recent insider activity, and a blended 0–100 "temperature" where 50 is
/// balanced, >50 leans buying and <50 leans selling.
struct MarketPressureResponse: Content, Equatable {
    let symbol: String
    let asOf: String
    let temperature: Double
    let label: String
    let volume: MarketPressureVolume
    let insider: MarketPressureInsider?
    let history: [MarketPressureHistoryPoint]
}

struct MarketPressureVolume: Content, Equatable {
    let today: Double
    let average30d: Double
    /// today / average30d; 1.0 = normal, 3.0 = 3x the usual traffic.
    let relative: Double
    let changePct: Double
}

struct MarketPressureInsider: Content, Equatable {
    let windowDays: Int
    let buyCount: Int
    let sellCount: Int
    let netShares: Double
    let lastActivityAt: String?
    let notable: [MarketPressureInsiderTrade]
}

struct MarketPressureInsiderTrade: Content, Equatable {
    let name: String
    let role: String?
    let side: String // "buy" | "sell"
    let shares: Double
    let date: String
}

struct MarketPressureHistoryPoint: Content, Equatable {
    let date: String
    /// Session volume / trailing 30-session average — the temperature-graph series.
    let relativeVolume: Double
}

// MARK: - FMP wire model

/// `/stable/insider-trading/search` item.
///
/// Every field is optional because FMP omits rather than nulls, and a plan that
/// does not cover a column simply leaves it out. Shared by the pressure snapshot
/// and by `/v1/market/insider/:symbol`.
struct FMPInsiderTrade: Codable, Sendable {
    let symbol: String?
    let filingDate: String?
    let transactionDate: String?
    let transactionType: String?
    let securitiesTransacted: Double?
    /// Shares the reporter held after the transaction settled.
    let securitiesOwned: Double?
    /// Price per share. Zero for awards and gifts, where it means "no price",
    /// not "free".
    let price: Double?
    let reportingName: String?
    let typeOfOwner: String?
    let acquisitionOrDisposition: String?
    /// Link to the SEC filing the row was extracted from.
    let url: String?
}
