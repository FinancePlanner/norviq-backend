import Foundation
import StockPlanShared

enum MarketBriefError: Error, Equatable {
    case unparseableDraft
    case tooFewItems(language: String, kept: Int)
    case incompleteBrief
}

/// The "SERVER-SELECTED FACTS" block: everything the model may quote without
/// a source. Same idea as `AIPrompt`'s facts: the server chooses the numbers
/// and the model only writes words around them.
struct MarketBriefFacts: Encodable, Sendable, Equatable {
    struct Quote: Encodable, Sendable, Equatable {
        let symbol: String
        let name: String
        let price: Double
        let previousClose: Double
        let changePercent: Double
    }

    struct Headline: Encodable, Sendable, Equatable {
        let title: String
        let source: String?
        let url: String?
        let publishedAt: String
    }

    struct Earnings: Encodable, Sendable, Equatable {
        let symbol: String
        let hour: String?
        let epsEstimate: Double?
        let epsActual: Double?
        let revenueEstimate: Double?
        let revenueActual: Double?
    }

    let slot: MarketBriefSlot
    let tradingDate: String
    let quotes: [Quote]
    let headlines: [Headline]
    let earnings: [Earnings]

    static let maxHeadlines = 25
    static let maxEarnings = 20
    static let headlineMaxAge: TimeInterval = 24 * 3600

    static func build(
        slot: MarketBriefSlot,
        tradingDate: String,
        quotes: [IndexQuote],
        news: [ProviderNewsItem],
        earnings: [EarningsItemResponse],
        now: Date
    ) -> MarketBriefFacts {
        let iso = ISO8601DateFormatter()
        return MarketBriefFacts(
            slot: slot,
            tradingDate: tradingDate,
            quotes: quotes.map { quote in
                Quote(
                    symbol: quote.symbol,
                    name: MarketBriefCatalog.instrument(symbol: quote.symbol)?.name ?? quote.symbol,
                    price: round2(quote.price),
                    previousClose: round2(quote.previousClose),
                    changePercent: round2(quote.changePercent)
                )
            },
            headlines: news
                .filter { now.timeIntervalSince($0.publishedAt) <= headlineMaxAge }
                .sorted { $0.publishedAt > $1.publishedAt }
                .prefix(maxHeadlines)
                .map { Headline(title: $0.headline, source: $0.source, url: $0.url, publishedAt: iso.string(from: $0.publishedAt)) },
            earnings: earnings.prefix(maxEarnings).compactMap { item in
                guard let symbol = item.symbol, !symbol.isEmpty else { return nil }
                return Earnings(
                    symbol: symbol,
                    hour: item.hour,
                    epsEstimate: item.epsEstimate,
                    epsActual: item.epsActual,
                    revenueEstimate: item.revenueEstimate,
                    revenueActual: item.revenueActual
                )
            }
        )
    }

    /// Every number an unsourced line may contain.
    var groundedNumbers: [Double] {
        var numbers: [Double] = []
        for quote in quotes {
            numbers += [quote.price, quote.previousClose, quote.changePercent, abs(quote.changePercent)]
        }
        for item in earnings {
            numbers += [item.epsEstimate, item.epsActual].compactMap(\.self)
            // Revenue is written as "$40.5B" or "40 500 M", so ground it at
            // every scale a sentence might use.
            for revenue in [item.revenueEstimate, item.revenueActual].compactMap(\.self) {
                numbers += [revenue, Self.round2(revenue / 1e9), Self.round2(revenue / 1e6)]
            }
        }
        for headline in headlines {
            numbers += MarketBriefNumbers.tokens(in: headline.title).flatMap(\.readings)
        }
        return numbers
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded(.toNearestOrAwayFromZero) / 100
    }
}

/// Finds the numbers the grounding check cares about.
enum MarketBriefNumbers {
    struct Token: Equatable {
        /// Every value the token could mean.
        let readings: [Double]
        /// How far a reading may sit from a fact and still match it: about one
        /// decimal of rounding for "0,8", half a unit for whole numbers.
        let tolerance: Double
    }

    /// Checked: numbers with a decimal or thousands separator ("25.032",
    /// "0,77", "24 150"), and whole numbers that read as a level (1000 or
    /// more, not a year), a percentage ("2%") or money ("$40B"). Unchecked:
    /// years, small counts and index names ("S&P 500", "CAC 40"), which are
    /// rarely the invented part of a market sentence.
    static func tokens(in text: String) -> [Token] {
        let pattern = #/(?<currency>[$€£])?(?<number>\d{1,3}(?:[ \u{00A0}\u{202F}]\d{3})+(?!\d)|\d+(?:[.,]\d+)+|\d+)(?<percent>\s?%)?/#
        return text.matches(of: pattern).compactMap { match in
            let raw = String(match.output.number)
            if raw.contains(where: { $0 == "." || $0 == "," }) {
                return Token(readings: readings(raw), tolerance: 0.051)
            }
            let digits = raw.filter(\.isNumber)
            guard let value = Double(digits) else { return nil }
            let spaceGrouped = digits.count != raw.count
            let isLevel = value >= 1000 && !(1900 ... 2100).contains(value)
            guard spaceGrouped || isLevel || match.output.percent != nil || match.output.currency != nil else {
                return nil
            }
            return Token(readings: [value], tolerance: 0.5)
        }
    }

    /// Both readings, because the token's language is unknown:
    /// "25.032" is 25.032 in en and 25032 in pt-PT.
    static func readings(_ token: String) -> [Double] {
        let english = Double(token.replacingOccurrences(of: ",", with: ""))
        let portuguese = Double(token.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "."))
        return [english, portuguese].compactMap(\.self)
    }
}
