import Foundation

struct PilotBookEntry: Sendable, Equatable {
    let symbol: String
    let side: PilotTradeSide
    let instrument: PilotInstrumentKind
    let transactionDate: String?
    let amountMin: Double?
    let amountMax: Double?
    let marketValue: Double?
    let period: String?
}

struct PilotBook: Sendable, Equatable {
    let weights: [String: Double]
    let skippedPuts: Int
}

/// Turns a pilot's disclosures into target weights. Pure: no I/O, no clock.
///
/// Politicians disclose dollar brackets, not positions, so exposure is an
/// estimate: buys add the bracket midpoint, partial sales subtract it, and a
/// full sale zeroes the position. Calls count as the underlying. Puts are
/// bearish and a mirrored portfolio cannot go short, so they are counted and
/// left out.
enum PilotBookBuilder {
    static func estimatedValue(min: Double?, max: Double?) -> Double? {
        switch (min, max) {
        case let (lo?, hi?): (lo + hi) / 2
        case let (lo?, nil): lo
        case let (nil, hi?): hi
        case (nil, nil): nil
        }
    }

    static func politicianBook(_ entries: [PilotBookEntry], asOf: Date, lookbackMonths: Int = 24) -> PilotBook {
        let cutoff = cutoffDate(asOf: asOf, months: lookbackMonths)
        // Same-day rows keep their input order: Swift's sort is not guaranteed
        // stable, and a buy and a full sale on one day must not swap.
        let ordered = entries.enumerated()
            .filter { ($0.element.transactionDate ?? "") >= cutoff }
            .sorted { ($0.element.transactionDate ?? "", $0.offset) < ($1.element.transactionDate ?? "", $1.offset) }
            .map(\.element)

        var exposure: [String: Double] = [:]
        var skippedPuts = 0
        for entry in ordered {
            if entry.instrument == .put {
                skippedPuts += 1
                continue
            }
            switch entry.side {
            case .buy:
                guard let value = estimatedValue(min: entry.amountMin, max: entry.amountMax) else { continue }
                exposure[entry.symbol, default: 0] += value
            case .sell:
                guard let current = exposure[entry.symbol],
                      let value = estimatedValue(min: entry.amountMin, max: entry.amountMax) else { continue }
                exposure[entry.symbol] = Swift.max(0, current - value)
            case .sellFull:
                exposure[entry.symbol] = nil
            case .hold:
                continue
            }
        }
        return PilotBook(weights: normalize(exposure), skippedPuts: skippedPuts)
    }

    static func fundBook(_ entries: [PilotBookEntry]) -> PilotBook {
        let holds = entries.filter { $0.side == .hold && $0.period != nil }
        guard let latest = holds.compactMap(\.period).max() else {
            return PilotBook(weights: [:], skippedPuts: 0)
        }
        var exposure: [String: Double] = [:]
        for entry in holds where entry.period == latest {
            exposure[entry.symbol, default: 0] += entry.marketValue ?? 0
        }
        return PilotBook(weights: normalize(exposure), skippedPuts: 0)
    }

    private static func normalize(_ exposure: [String: Double]) -> [String: Double] {
        let positive = exposure.filter { $0.value > 0 }
        let total = positive.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return positive.mapValues { $0 / total }
    }

    /// `yyyy-MM-dd`, compared as a string against FMP's dates.
    private static func cutoffDate(asOf: Date, months: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let cutoff = calendar.date(byAdding: .month, value: -months, to: asOf) ?? asOf
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: cutoff)
    }
}
