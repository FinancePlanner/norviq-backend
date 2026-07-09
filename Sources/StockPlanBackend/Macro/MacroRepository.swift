import Fluent
import Foundation

protocol MacroRepository: Sendable {
    /// Appends a snapshot if none exists for (country, asOf, source). Returns true when inserted.
    @discardableResult
    func insertSnapshotIfNew(_ snapshot: MacroSnapshotRecord, on db: any Database) async throws -> Bool
    func latestSnapshot(country: String, on db: any Database) async throws -> MacroSnapshotRecord?
    /// Vintage-safe insert: a point is written only when no prior vintage exists
    /// for (country, seriesKey, periodDate, source) or the latest vintage has a
    /// different value. Existing rows are never mutated. Returns inserted count.
    func insertPointsIfChanged(_ points: [MacroSeriesPointRecord], on db: any Database) async throws -> Int
    /// Latest vintage per period, ascending by period date.
    func series(country: String, seriesKey: String, from: String?, to: String?, limit: Int, on db: any Database) async throws -> [MacroSeriesPointRecord]
    func latestPoint(country: String, seriesKey: String, on db: any Database) async throws -> MacroSeriesPointRecord?
    /// Most recent snapshot fetch time per country (for readiness/freshness).
    func freshness(on db: any Database) async throws -> [String: Date]
}

struct DatabaseMacroRepository: MacroRepository {
    @discardableResult
    func insertSnapshotIfNew(_ snapshot: MacroSnapshotRecord, on db: any Database) async throws -> Bool {
        let exists = try await MacroSnapshotRecord.query(on: db)
            .filter(\.$country == snapshot.country)
            .filter(\.$asOf == snapshot.asOf)
            .filter(\.$source == snapshot.source)
            .first() != nil
        guard !exists else { return false }
        try await snapshot.save(on: db)
        return true
    }

    func latestSnapshot(country: String, on db: any Database) async throws -> MacroSnapshotRecord? {
        try await MacroSnapshotRecord.query(on: db)
            .filter(\.$country == country)
            .sort(\.$fetchedAt, .descending)
            .first()
    }

    func insertPointsIfChanged(_ points: [MacroSeriesPointRecord], on db: any Database) async throws -> Int {
        guard !points.isEmpty else { return 0 }
        var inserted = 0
        // Group lookups per (country, seriesKey, source) to avoid one query per point.
        let groups = Dictionary(grouping: points) { "\($0.country)|\($0.seriesKey)|\($0.source)" }
        for (_, groupPoints) in groups {
            guard let sample = groupPoints.first else { continue }
            let periods = groupPoints.map(\.periodDate)
            let existing = try await MacroSeriesPointRecord.query(on: db)
                .filter(\.$country == sample.country)
                .filter(\.$seriesKey == sample.seriesKey)
                .filter(\.$source == sample.source)
                .filter(\.$periodDate ~~ periods)
                .all()
            // Latest vintage value per period.
            var latestByPeriod: [String: MacroSeriesPointRecord] = [:]
            for row in existing {
                if let current = latestByPeriod[row.periodDate] {
                    if row.vintageDate > current.vintageDate {
                        latestByPeriod[row.periodDate] = row
                    }
                } else {
                    latestByPeriod[row.periodDate] = row
                }
            }
            for point in groupPoints {
                if let latest = latestByPeriod[point.periodDate], latest.value == point.value {
                    continue
                }
                try await point.save(on: db)
                inserted += 1
            }
        }
        return inserted
    }

    func series(country: String, seriesKey: String, from: String?, to: String?, limit: Int, on db: any Database) async throws -> [MacroSeriesPointRecord] {
        let query = MacroSeriesPointRecord.query(on: db)
            .filter(\.$country == country)
            .filter(\.$seriesKey == seriesKey)
        if let from, !from.isEmpty {
            query.filter(\.$periodDate >= from)
        }
        if let to, !to.isEmpty {
            query.filter(\.$periodDate <= to)
        }
        let rows = try await query.all()
        // Latest vintage per period, then ascending by period, capped to the
        // most recent `limit` periods.
        var latestByPeriod: [String: MacroSeriesPointRecord] = [:]
        for row in rows {
            if let current = latestByPeriod[row.periodDate] {
                if row.vintageDate > current.vintageDate {
                    latestByPeriod[row.periodDate] = row
                }
            } else {
                latestByPeriod[row.periodDate] = row
            }
        }
        let ordered = latestByPeriod.values.sorted { $0.periodDate < $1.periodDate }
        if ordered.count > limit {
            return Array(ordered.suffix(limit))
        }
        return ordered
    }

    func latestPoint(country: String, seriesKey: String, on db: any Database) async throws -> MacroSeriesPointRecord? {
        let rows = try await MacroSeriesPointRecord.query(on: db)
            .filter(\.$country == country)
            .filter(\.$seriesKey == seriesKey)
            .sort(\.$periodDate, .descending)
            .sort(\.$vintageDate, .descending)
            .limit(1)
            .all()
        return rows.first
    }

    func freshness(on db: any Database) async throws -> [String: Date] {
        let rows = try await MacroSnapshotRecord.query(on: db)
            .field(\.$country)
            .field(\.$fetchedAt)
            .sort(\.$fetchedAt, .descending)
            .limit(200)
            .all()
        var result: [String: Date] = [:]
        for row in rows where result[row.country] == nil {
            result[row.country] = row.fetchedAt
        }
        return result
    }
}
