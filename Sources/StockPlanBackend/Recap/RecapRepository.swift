import Fluent
import FluentPostgresDriver
import Foundation
import StockPlanShared

protocol RecapRepository: Sendable {
    func find(userId: UUID, kind: RecapPeriodKind, key: String, on db: any Database) async throws -> RecapRecord?
    func find(id: UUID, userId: UUID, on db: any Database) async throws -> RecapRecord?
    /// Inserts `record`, or, if a row for its (user, kind, key) already exists,
    /// returns that row instead. Must not run inside a transaction: the failed
    /// insert would abort it before the re-fetch.
    func insertOrFetch(_ record: RecapRecord, on db: any Database) async throws -> RecapRecord
    /// Newest `generated_at` first.
    func list(userId: UUID, on db: any Database) async throws -> [RecapRecord]
}

// `.first()` below is Fluent's query, not a collection.
// swiftlint:disable first_where
struct DatabaseRecapRepository: RecapRepository {
    func find(userId: UUID, kind: RecapPeriodKind, key: String, on db: any Database) async throws -> RecapRecord? {
        try await RecapRecord.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$periodKind == kind.rawValue)
            .filter(\.$periodKey == key)
            .first()
    }

    func find(id: UUID, userId: UUID, on db: any Database) async throws -> RecapRecord? {
        try await RecapRecord.query(on: db)
            .filter(\.$id == id)
            .filter(\.$userId == userId)
            .first()
    }

    func insertOrFetch(_ record: RecapRecord, on db: any Database) async throws -> RecapRecord {
        do {
            try await record.create(on: db)
            return record
        } catch where Self.isUniqueViolation(error) {
            guard let kind = RecapPeriodKind(rawValue: record.periodKind),
                  let existing = try await find(userId: record.userId, kind: kind, key: record.periodKey, on: db)
            else { throw error }
            return existing
        }
    }

    func list(userId: UUID, on db: any Database) async throws -> [RecapRecord] {
        try await RecapRecord.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$generatedAt, .descending)
            .all()
    }

    /// SQLSTATE 23505 only. `DatabaseError.isConstraintFailure` would also match
    /// a foreign-key violation (user deleted mid-request), which must not be
    /// swallowed as "someone else inserted first".
    static func isUniqueViolation(_ error: any Error) -> Bool {
        guard let psql = error as? PSQLError else { return false }
        return psql.serverInfo?[.sqlState] == "23505"
    }
}

// swiftlint:enable first_where
