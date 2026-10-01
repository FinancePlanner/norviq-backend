import Foundation
import StockPlanShared

/// Who a source should fetch for. Built from a `Pilot` row.
struct PilotSourceIdentity: Sendable {
    let kind: PilotKind
    /// `senate` or `house`; nil for funds.
    let chamber: String?
    /// Bioguide ID, e.g. `P000197`. The primary match for congress rows.
    let bioguideId: String?
    /// Exact "First Last" spellings, used only when a row has no bioguide ID.
    let aliases: [String]
    let cik: String?

    init(kind: PilotKind, chamber: String?, bioguideId: String?, aliases: [String], cik: String?) {
        self.kind = kind
        self.chamber = chamber
        self.bioguideId = bioguideId
        self.aliases = aliases
        self.cik = cik
    }

    init(_ pilot: Pilot) {
        self.init(kind: pilot.pilotKind, chamber: pilot.chamber, bioguideId: pilot.bioguideId, aliases: pilot.nameAliases, cik: pilot.cik)
    }
}

/// One disclosed trade or 13F holding, normalized. `sourceKey` is unique per
/// pilot and stable across fetches: it is what makes ingestion idempotent.
struct PilotDisclosureInput: Sendable, Equatable {
    let sourceKey: String
    let symbol: String
    let side: PilotTradeSide
    let instrument: PilotInstrumentKind
    let transactionDate: String?
    let disclosureDate: String?
    let amountMin: Double?
    let amountMax: Double?
    let shares: Double?
    let marketValue: Double?
    let period: String?
}

/// Supplies a pilot's disclosures. Named for what it provides, not for a
/// vendor, so switching data provider is a new conformer, not a rename.
protocol PilotDisclosureSource: Sendable {
    func disclosures(for pilot: PilotSourceIdentity) async throws -> [PilotDisclosureInput]
}
