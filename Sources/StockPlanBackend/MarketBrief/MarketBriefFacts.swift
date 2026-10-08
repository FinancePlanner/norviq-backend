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
            numbers += [quote.price, quote.changePercent, abs(quote.changePercent)]
        }
        for item in earnings {
            numbers += [item.epsEstimate, item.epsActual, item.revenueEstimate, item.revenueActual].compactMap(\.self)
        }
        for headline in headlines {
            numbers += MarketBriefNumbers.tokens(in: headline.title).flatMap(\.self)
        }
        return numbers
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded(.toNearestOrAwayFromZero) / 100
    }
}

/// Finds the numbers the grounding check cares about.
enum MarketBriefNumbers {
    /// Only tokens with a separator ("25.032", "0,77", "1,234.5"). Plain
    /// integers (years, counts) are not checked: they are rarely the made-up
    /// part of a market sentence, and checking them would drop most lines.
    static func tokens(in text: String) -> [[Double]] {
        text.matches(of: #/\d+(?:[.,]\d+)+/#).map { readings(String($0.output)) }
    }

    /// Both readings, because the token's language is unknown:
    /// "25.032" is 25.032 in en and 25032 in pt-PT.
    static func readings(_ token: String) -> [Double] {
        let english = Double(token.replacingOccurrences(of: ",", with: ""))
        let portuguese = Double(token.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "."))
        return [english, portuguese].compactMap(\.self)
    }
}
