import Fluent
import Foundation
import SQLKit
@testable import StockPlanBackend
import StockPlanShared
import Vapor
import VaporTesting

// swiftlint:disable force_unwrapping

/// Shared setup for the recap suites: a configured, migrated app inside the
/// shared DB lock, registered users, and helpers for seeding dated rows.
enum RecapFixtures {
    /// Configured, migrated app inside the shared DB lock.
    static func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withSharedAccess {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
                try await app.asyncShutdown()
            } catch {
                try? await app.autoRevert()
                try? await app.asyncShutdown()
                throw error
            }
        }
    }

    /// Configured app plus one freshly registered user: `(app, token, userId)`.
    static func withUser(_ test: (Application, String, UUID) async throws -> Void) async throws {
        try await withApp { app in
            let (token, userId) = try await registerUser(app: app)
            try await test(app, token, userId)
        }
    }

    static func registerUser(app: Application) async throws -> (token: String, userId: UUID) {
        let id = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "recap_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "recap_\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            token = try res.content.decode(AuthResponse.self).token
        })
        let userId = try await app.jwt.keys.verify(token, as: SessionToken.self).userId
        return (token, userId)
    }

    // MARK: - Dates

    /// `yyyy-MM-dd` as UTC midnight, the way `date` columns round-trip.
    static func day(_ ymd: String) -> Date {
        instant("\(ymd)T00:00:00Z")
    }

    static func instant(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    static func month(_ key: String) -> RecapPeriod {
        RecapPeriod.parse(kind: "month", key: key)!
    }

    static let utc = TimeZone(identifier: "UTC")!

    // MARK: - Seeding

    /// Overrides a `@Timestamp(on: .create)` column, which Fluent always sets to now.
    static func backdate(table: String, id: UUID, column: String = "created_at", to date: Date, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw("UPDATE \(ident: table) SET \(ident: column) = \(bind: date) WHERE id = \(bind: id)").run()
    }

    static func account(for userId: UUID, on db: any Database) async throws -> UUID {
        let account = Account(
            userId: userId, externalId: "recap-\(UUID().uuidString.prefix(8))",
            broker: "ibkr", baseCurrency: "USD"
        )
        try await account.save(on: db)
        return try account.requireID()
    }

    static func instrument(symbol: String, currency: String = "USD", on db: any Database) async throws -> UUID {
        let instrument = Instrument(
            conid: "recap-\(UUID().uuidString.prefix(8))", symbol: symbol,
            exchange: "NASDAQ", currency: currency
        )
        try await instrument.save(on: db)
        return try instrument.requireID()
    }

    static func portfolioList(for userId: UUID, on db: any Database) async throws -> UUID {
        let list = PortfolioList(userId: userId, name: "Recap \(UUID().uuidString.prefix(8))", isDefault: false)
        try await list.save(on: db)
        return try list.requireID()
    }

    static func checkIn(_ userId: UUID, _ localDate: String, timeZone: String = "UTC", on db: any Database) async throws {
        try await GamificationCheckIn(userId: userId, localDate: localDate, timeZone: timeZone).save(on: db)
    }

    static func snapshot(
        _ userId: UUID, list: UUID, on capturedOn: String, value: Double, currency: String = "USD", db: any Database
    ) async throws {
        try await PortfolioValueSnapshot(
            userId: userId, portfolioListId: list, capturedOn: day(capturedOn), currency: currency,
            marketValue: value, costBasis: value, cashBalance: 0, positionCount: 1, source: .live,
            pricedSymbols: 1, missingSymbols: 0
        ).save(on: db)
    }
}

// swiftlint:enable force_unwrapping
