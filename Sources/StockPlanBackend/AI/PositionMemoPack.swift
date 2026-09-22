import Foundation
import StockPlanShared

/// Curated snapshot the memo writer is allowed to use. Nil and empty mean the
/// figure was not fetched, not that it is zero.
struct PositionMemoPack: Codable, Equatable, Sendable {
    var askedSymbol: String
    var primarySymbol: String
    var listings: [Listing]
    var quotes: [Quote]
    var fx: FX?
    var profile: Profile?
    var income: [IncomeYear]
    var balance: Balance?
    var cashFlow: CashFlow?
    var ratios: Ratios?
    var growth: Growth?
    var estimates: [Estimate]
    var grades: Grades?
    var technicals: Technicals?
    var insider: Insider?
    var news: [Headline]
    var nextEarningsDate: String?
    var holding: Holding?
    var notes: [Note]
    var targets: [TargetLine]
    var basicMetrics: [String: Double]
    var unavailable: [String]

    struct Listing: Codable, Equatable, Sendable {
        var symbol: String
        var name: String
        var exchange: String
        var currency: String
    }

    struct Quote: Codable, Equatable, Sendable {
        var symbol: String
        var currency: String
        var price: Double
        var previousClose: Double?
        var change: Double?
        var percentChange: Double?
        var high: Double?
        var low: Double?
        var volume: Int?
        var asOf: String?
    }

    struct FX: Codable, Equatable, Sendable {
        var pair: String
        var rate: Double
        var date: String
    }

    struct Profile: Codable, Equatable, Sendable {
        var name: String?
        var country: String?
        var exchange: String?
        var currency: String?
        var industry: String?
        var ipo: String?
        var shareOutstandingMillions: Double?
        var marketCapitalization: Double?
        var weburl: String?
    }

    struct IncomeYear: Codable, Equatable, Sendable {
        var date: String
        var fiscalYear: String?
        var revenue: Double?
        var operatingIncome: Double?
        var netIncome: Double?
        var interestIncome: Double?
        var epsDiluted: Double?
    }

    struct Balance: Codable, Equatable, Sendable {
        var date: String
        var cashAndEquivalents: Double?
        var shortTermInvestments: Double?
        var totalDebt: Double?
        var totalEquity: Double?
    }

    struct CashFlow: Codable, Equatable, Sendable {
        var date: String
        var operatingCashFlow: Double?
        var freeCashFlow: Double?
    }

    struct Ratios: Codable, Equatable, Sendable {
        var operatingMargin: Double?
        var netMargin: Double?
        var priceToEarnings: Double?
        var priceToBook: Double?
        var priceToSales: Double?
        var enterpriseValue: Double?
    }

    struct Growth: Codable, Equatable, Sendable {
        var date: String
        var revenueGrowth: Double?
        var netIncomeGrowth: Double?
    }

    struct Estimate: Codable, Equatable, Sendable {
        var date: String
        var revenueAvg: Double?
        var epsAvg: Double?
        var epsLow: Double?
        var epsHigh: Double?
        var analystCount: Int?
    }

    struct Grades: Codable, Equatable, Sendable {
        var strongBuy: Int?
        var buy: Int?
        var hold: Int?
        var sell: Int?
        var strongSell: Int?
        var consensus: String?
    }

    struct Technicals: Codable, Equatable, Sendable {
        var asOf: String
        var close: Double
        var sma50: Double?
        var sma200: Double?
        var trend: String
        var fiftyTwoWeekHigh: Double?
        var fiftyTwoWeekLow: Double?
    }

    struct Insider: Codable, Equatable, Sendable {
        var buys: Int
        var sells: Int
        var netShares: Double
        var netValue: Double
        var recent: [Trade]

        struct Trade: Codable, Equatable, Sendable {
            var date: String
            var name: String
            var kind: String
            var shares: Double
            var value: Double?
        }
    }

    struct Headline: Codable, Equatable, Sendable {
        var title: String
        var url: String
        var date: String
        var source: String?
    }

    struct Holding: Codable, Equatable, Sendable {
        var symbol: String
        var shares: Double
        var averageBuyPrice: Double
        var lotCount: Int
    }

    struct Note: Codable, Equatable, Sendable {
        var symbol: String
        var title: String?
        var thesis: String
    }

    struct TargetLine: Codable, Equatable, Sendable {
        var symbol: String
        var scenario: String
        var targetPrice: Double
        var targetDate: String?
    }
}

enum PositionMemoDraftGuard {
    static func apply(_ draft: PositionMemoDraft, pack: PositionMemoPack) -> PositionMemoDraft {
        var sections = draft.sections.filter { section in
            section.heading.caseInsensitiveCompare("Your mark") != .orderedSame
                && section.heading.caseInsensitiveCompare("Verdict") != .orderedSame
        }
        if pack.income.isEmpty {
            sections.removeAll { $0.heading.caseInsensitiveCompare("The business") == .orderedSame }
            sections.append(PositionMemoSection(heading: "The business", paragraphs: [PositionMemoCopy.unavailableBusiness]))
        }
        return PositionMemoDraft(title: draft.title, verdict: draft.verdict, sections: sections)
    }
}

enum PositionMemoSources {
    static func build(pack: PositionMemoPack, mark: PositionMemoMark) -> [PositionMemoSource] {
        var sources: [PositionMemoSource] = []
        for quote in pack.quotes {
            sources.append(PositionMemoSource(label: "Quote", symbol: quote.symbol, asOf: quote.asOf, url: nil))
        }
        if pack.fx != nil {
            sources.append(PositionMemoSource(label: "FX", symbol: mark.fxPair, asOf: pack.fx?.date, url: nil))
        }
        if pack.profile != nil {
            sources.append(PositionMemoSource(label: "Company profile", symbol: pack.primarySymbol, asOf: nil, url: pack.profile?.weburl))
        }
        if !pack.income.isEmpty {
            sources.append(PositionMemoSource(label: "Income statement", symbol: pack.primarySymbol, asOf: pack.income.first?.date, url: nil))
        }
        if pack.balance != nil {
            sources.append(PositionMemoSource(label: "Balance sheet", symbol: pack.primarySymbol, asOf: pack.balance?.date, url: nil))
        }
        if pack.cashFlow != nil {
            sources.append(PositionMemoSource(label: "Cash flow statement", symbol: pack.primarySymbol, asOf: pack.cashFlow?.date, url: nil))
        }
        if pack.ratios != nil {
            sources.append(PositionMemoSource(label: "Ratios", symbol: pack.primarySymbol, asOf: nil, url: nil))
        }
        if !pack.estimates.isEmpty {
            sources.append(PositionMemoSource(label: "Analyst estimates", symbol: pack.primarySymbol, asOf: pack.estimates.first?.date, url: nil))
        }
        if pack.grades != nil {
            sources.append(PositionMemoSource(label: "Analyst grades", symbol: pack.primarySymbol, asOf: nil, url: nil))
        }
        if pack.insider != nil {
            sources.append(PositionMemoSource(label: "Insider filings", symbol: pack.primarySymbol, asOf: pack.insider?.recent.first?.date, url: nil))
        }
        if pack.technicals != nil {
            sources.append(PositionMemoSource(label: "Technicals", symbol: pack.primarySymbol, asOf: pack.technicals?.asOf, url: nil))
        }
        for headline in pack.news.prefix(8) {
            sources.append(PositionMemoSource(label: headline.source ?? "News", symbol: pack.primarySymbol, asOf: headline.date, url: headline.url))
        }
        if pack.holding != nil {
            sources.append(PositionMemoSource(label: "Your lots", symbol: pack.holding?.symbol, asOf: nil, url: nil))
        }
        return sources
    }
}
