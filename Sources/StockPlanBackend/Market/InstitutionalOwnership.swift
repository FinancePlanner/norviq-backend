import Foundation
import Vapor

// MARK: - /v1/market/institutional/:symbol response

struct InstitutionalHolder: Content, Equatable {
    /// The filer's name as it appears on the 13F.
    let name: String
    let shares: Double
    let marketValue: Double?
    /// Change in shares held against the previous quarter. Negative is a trim.
    let changeInShares: Double?
    /// That change as a percentage of the previous quarter's position.
    let changePct: Double?
    /// The position's weight in the filer's own portfolio, as a percentage,
    /// exactly as the upstream filing analytics report it.
    let weightPct: Double?
}

struct InstitutionalOwnershipResponse: Content, Equatable {
    let symbol: String
    /// The 13F quarter the figures are drawn from, e.g. `2026Q2`. 13Fs are
    /// filed after the quarter ends, so this is never the current quarter.
    let asOfQuarter: String
    /// Number of institutions holding the symbol. Null when the positions
    /// summary was unavailable.
    let holdersCount: Int?
    /// Institutional ownership as a percentage of shares outstanding. Null
    /// when the positions summary was unavailable.
    let institutionalOwnershipPct: Double?
    /// Total shares held across all 13F filers. Null when the positions
    /// summary was unavailable.
    let totalShares: Double?
    /// The ten largest holders by share count, largest first. Empty when no
    /// holder analytics came back for the quarter, or when the upstream plan
    /// does not cover them.
    let topHolders: [InstitutionalHolder]
}

// MARK: - FMP wire model

/// A `/stable/institutional-ownership/extract-analytics/holder` item (the
/// fields this feature uses).
struct FMPInstitutionalHolder: Codable, Sendable {
    let investorName: String?
    let sharesNumber: Double?
    let marketValue: Double?
    let changeInSharesNumber: Double?
    let changeInSharesNumberPercentage: Double?
    let weight: Double?
}

/// A `/stable/institutional-ownership/symbol-positions-summary` item (the
/// fields this feature uses).
struct FMPInstitutionalPositionsSummary: Codable, Sendable {
    let symbol: String?
    let date: String?
    let investorsHolding: Int?
    let numberOf13Fshares: Double?
    let ownershipPercent: Double?
}

// MARK: - Quarters

/// A calendar quarter, which is the unit 13F ownership data is reported in.
struct MarketQuarter: Equatable, Sendable {
    let year: Int
    /// 1…4.
    let quarter: Int

    /// `2026Q2`.
    var label: String {
        "\(year)Q\(quarter)"
    }

    /// The quarter before this one, wrapping into the previous year from Q1.
    func previous() -> MarketQuarter {
        quarter > 1
            ? MarketQuarter(year: year, quarter: quarter - 1)
            : MarketQuarter(year: year - 1, quarter: 4)
    }

    /// The newest quarter that could have been reported by `asOf`: the
    /// calendar quarter before the one `asOf` falls in.
    ///
    /// This is the newest quarter that *exists*, not necessarily the newest one
    /// with data — 13Fs are due 45 days after the quarter closes, so early in a
    /// quarter the previous one is often still empty. The caller steps back
    /// with `previous()` when that happens.
    static func latestReported(asOf: Date = Date()) -> MarketQuarter {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.year, .month], from: asOf)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let current = MarketQuarter(year: year, quarter: (month - 1) / 3 + 1)
        return current.previous()
    }
}

// MARK: - Assembly

enum InstitutionalOwnership {
    static let topHolderLimit = 10

    static func redisKey(_ symbol: String) -> String {
        "market:institutional:\(symbol)"
    }

    /// The largest holders by share count, largest first, capped at ten.
    ///
    /// A row with no filer name or no share count is dropped rather than
    /// published as an unnamed or zero-share holder: both would sort and read
    /// as real positions.
    static func holders(from wire: [FMPInstitutionalHolder]) -> [InstitutionalHolder] {
        let ranked = wire
            .compactMap { row -> InstitutionalHolder? in
                guard let name = row.investorName?.nonEmptyTrimmed, let shares = row.sharesNumber else {
                    return nil
                }
                return InstitutionalHolder(
                    name: name,
                    shares: shares,
                    marketValue: row.marketValue,
                    changeInShares: row.changeInSharesNumber,
                    changePct: row.changeInSharesNumberPercentage,
                    weightPct: row.weight
                )
            }
            .sorted { $0.shares > $1.shares }
        return Array(ranked.prefix(topHolderLimit))
    }

    /// Assembles the response. Either half may be missing — the holder
    /// analytics and the positions summary are separate upstream calls — and
    /// whichever arrived is returned.
    static func build(
        symbol: String,
        quarter: MarketQuarter,
        wireHolders: [FMPInstitutionalHolder],
        summary: FMPInstitutionalPositionsSummary?
    ) -> InstitutionalOwnershipResponse {
        InstitutionalOwnershipResponse(
            symbol: symbol,
            asOfQuarter: quarter.label,
            holdersCount: summary?.investorsHolding,
            institutionalOwnershipPct: summary?.ownershipPercent,
            totalShares: summary?.numberOf13Fshares,
            topHolders: holders(from: wireHolders)
        )
    }
}
