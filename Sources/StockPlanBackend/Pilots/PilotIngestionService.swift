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

        // Network fetch happens outside any transaction.
        let rows = try await source.disclosures(for: PilotSourceIdentity(pilot))
        let kind = pilot.pilotKind

        // Inserts, version rebuild and lastIngestedAt commit together, so a
        // failure never strands rows behind an "unchanged" next run.
        return try await db.transaction { tx -> PilotIngestOutcome in
            guard let txSql = tx as? any SQLDatabase else { return .unchanged }
            // Serialize ingestion per pilot so two pods cannot write the same version.
            _ = try await txSql.raw("SELECT id FROM pilots WHERE id = \(bind: pilotId) FOR UPDATE").all()

            var inserted = 0
            for row in rows {
                let result = try await txSql.raw("""
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

            let latest = try await PilotBookVersion.query(on: tx).filter(\.$pilotId == pilotId).sort(\.$version, .descending).first()
            var outcome = PilotIngestOutcome.unchanged
            if inserted > 0 || latest == nil {
                let entries = try await PilotDisclosureRecord.query(on: tx).filter(\.$pilotId == pilotId).all().compactMap { record -> PilotBookEntry? in
                    guard let side = PilotTradeSide(rawValue: record.side), let instrument = PilotInstrumentKind(rawValue: record.instrument) else { return nil }
                    return PilotBookEntry(symbol: record.symbol, side: side, instrument: instrument, transactionDate: record.transactionDate, amountMin: record.amountMin, amountMax: record.amountMax, marketValue: record.marketValue, period: record.period)
                }
                let book = kind == .politician
                    ? PilotBookBuilder.politicianBook(entries, asOf: now)
                    : PilotBookBuilder.fundBook(entries)
                if !book.weights.isEmpty {
                    let next = (latest?.version ?? 0) + 1
                    try await PilotBookVersion(pilotId: pilotId, version: next, computedAt: now, weights: book.weights, skippedPuts: book.skippedPuts).create(on: tx)
                    outcome = .newVersion(next)
                }
            }

            pilot.lastIngestedAt = now
            try await pilot.save(on: tx)
            return outcome
        }
    }
}
