import Fluent
import Foundation
import SQLKit
import StockPlanShared

enum PilotIngestOutcome: Equatable {
    case unchanged
    case newVersion(Int)
}

/// Pulls a pilot's disclosures, stores the new ones, and writes a new book
/// version only when something was new. Re-running on unchanged data is a
/// no-op, guaranteed by unique (pilot_id, source_key).
struct PilotIngestionService: Sendable {
    private let politicians: any PilotDisclosureSource
    private let funds: (any PilotDisclosureSource)?

    init(politicians: any PilotDisclosureSource, funds: (any PilotDisclosureSource)?) {
        self.politicians = politicians
        self.funds = funds
    }

    func ingest(pilot: Pilot, now: Date, on db: any Database) async throws -> PilotIngestOutcome {
        let pilotId = try pilot.requireID()
        let source: (any PilotDisclosureSource)? = pilot.pilotKind == .politician ? politicians : funds
        guard let source, let sql = db as? any SQLDatabase else { return .unchanged }

        let rows = try await source.disclosures(for: PilotSourceIdentity(pilot))
        var inserted = 0
        for row in rows {
            let result = try await sql.raw("""
            INSERT INTO pilot_disclosures (pilot_id, source_key, symbol, side, instrument, transaction_date, disclosure_date,
                                           amount_min, amount_max, shares, market_value, period, discovered_at)
            VALUES (\(bind: pilotId), \(bind: row.sourceKey), \(bind: row.symbol), \(bind: row.side.rawValue), \(bind: row.instrument.rawValue),
                    \(bind: row.transactionDate), \(bind: row.disclosureDate), \(bind: row.amountMin), \(bind: row.amountMax),
                    \(bind: row.shares), \(bind: row.marketValue), \(bind: row.period), \(bind: now))
            ON CONFLICT (pilot_id, source_key) DO NOTHING
            RETURNING id
            """).all()
            inserted += result.count
        }

        pilot.lastIngestedAt = now
        try await pilot.save(on: db)

        let latest = try await PilotBookVersion.query(on: db).filter(\.$pilotId == pilotId).sort(\.$version, .descending).first()
        guard inserted > 0 || latest == nil else { return .unchanged }

        let entries = try await PilotDisclosureRecord.query(on: db).filter(\.$pilotId == pilotId).all().compactMap { record -> PilotBookEntry? in
            guard let side = PilotTradeSide(rawValue: record.side), let instrument = PilotInstrumentKind(rawValue: record.instrument) else { return nil }
            return PilotBookEntry(symbol: record.symbol, side: side, instrument: instrument, transactionDate: record.transactionDate, amountMin: record.amountMin, amountMax: record.amountMax, marketValue: record.marketValue, period: record.period)
        }
        let book = pilot.pilotKind == .politician
            ? PilotBookBuilder.politicianBook(entries, asOf: now)
            : PilotBookBuilder.fundBook(entries)
        guard !book.weights.isEmpty else { return .unchanged }

        let next = (latest?.version ?? 0) + 1
        try await PilotBookVersion(pilotId: pilotId, version: next, computedAt: now, weights: book.weights, skippedPuts: book.skippedPuts).create(on: db)
        return .newVersion(next)
    }
}
