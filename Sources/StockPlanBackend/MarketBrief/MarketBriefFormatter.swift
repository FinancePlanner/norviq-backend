import Foundation
import StockPlanShared

/// Turns quotes into display rows, formatted on the server so neither client
/// formats numbers.
///
/// Hand-rolled rather than `NumberFormatter`: ICU's pt_PT uses a space as the
/// thousands separator and skips grouping for four-digit numbers ("7698"),
/// but the brief's house style is "7.698", and Linux and Darwin ICU builds
/// do not always agree.
enum MarketBriefFormatter {
    /// Mean moves inside ±0.15 points read as "mixed", not up or down.
    static let toneBand = 0.15

    static func number(_ value: Double, decimals: Int, language: MarketBriefLanguage) -> String {
        let (decimalSeparator, groupingSeparator) = language == .en ? (".", ",") : (",", ".")
        var scale = 1
        for _ in 0 ..< decimals {
            scale *= 10
        }
        let units = Int((abs(value) * Double(scale)).rounded(.toNearestOrAwayFromZero))
        let digits = String(units / scale)
        var grouped = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 {
                grouped += groupingSeparator
            }
            grouped.append(character)
        }
        let sign = value < 0 && units != 0 ? "-" : ""
        guard decimals > 0 else { return sign + grouped }
        let fraction = String(units % scale)
        let padded = String(repeating: "0", count: decimals - fraction.count) + fraction
        return sign + grouped + decimalSeparator + padded
    }

    static func level(_ value: Double, language: MarketBriefLanguage) -> String {
        number(value, decimals: abs(value) >= 1000 ? 0 : 2, language: language)
    }

    static func percent(_ change: Double, language: MarketBriefLanguage) -> String {
        number(abs(change), decimals: 2, language: language) + "%"
    }

    /// Decided on the value as shown (two decimals), so a row never reads
    /// "🔴 0,00%".
    static func direction(_ change: Double) -> MarketBriefDirection {
        let shown = (change * 100).rounded(.toNearestOrAwayFromZero) / 100
        if shown > 0 {
            return .up
        }
        if shown < 0 {
            return .down
        }
        return .flat
    }

    static func tone(_ changes: [Double]) -> MarketBriefDirection {
        guard !changes.isEmpty else { return .flat }
        let mean = changes.reduce(0, +) / Double(changes.count)
        if mean > toneBand {
            return .up
        }
        if mean < -toneBand {
            return .down
        }
        return .flat
    }

    static func groups(slot: MarketBriefSlot, quotes: [IndexQuote], language: MarketBriefLanguage) -> [MarketBriefQuoteGroup] {
        let bySymbol = Dictionary(quotes.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        return MarketBriefCatalog.groups(for: slot).compactMap { spec in
            let present = spec.instruments.compactMap { instrument in bySymbol[instrument.symbol].map { (instrument, $0) } }
            guard !present.isEmpty else { return nil }
            let tone = tone(present.map(\.1.changePercent))
            return MarketBriefQuoteGroup(
                id: spec.id,
                title: MarketBriefCatalog.title(groupId: spec.id, tone: tone, language: language),
                tone: tone,
                rows: present.map { instrument, quote in
                    MarketBriefQuoteRow(
                        symbol: instrument.symbol,
                        flag: instrument.flag,
                        name: instrument.name,
                        level: level(quote.price, language: language),
                        changePercent: percent(quote.changePercent, language: language),
                        direction: direction(quote.changePercent)
                    )
                }
            )
        }
    }
}
