import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

/// Gates that must hold before pilot follows are enabled anywhere: no real
/// writer may reach a followed portfolio, a pilot portfolio never becomes the
/// default, simulated trades stay out of tax advice, and the pilot account and
/// provider name stay reserved. Each test also pins the unfollowed behaviour.
@Suite("Staging gates", .serialized)
struct StagingGatesTests {
    func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withSharedAccess {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    func registerTestUser(app: Application) async throws -> (token: String, userId: UUID) {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        let request = StockPlanBackend.AuthRegisterRequest(
            username: "gate_\(suffix)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "gate+\(suffix)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var response: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })
        guard let response else {
            throw Abort(.internalServerError, reason: "Auth register did not return a response")
        }
        return (response.token, response.userId)
    }

    func grantPro(_ userId: UUID, on app: Application) async throws {
        try await Entitlement(userId: userId, level: "pro").save(on: app.db)
    }

    struct FollowedList {
        let listId: UUID
        let follow: PilotFollow
        let pilotAccount: Account
        let stockId: UUID
    }

    /// A hypothetical portfolio a pilot follows: the pilot account holds 1000
    /// of simulated cash and the portfolio 5 simulated AAPL.
    func seedFollowedList(userId: UUID, name: String? = nil, on db: any Database) async throws -> FollowedList {
        let pilot = Pilot(kind: .politician, slug: "g-\(UUID().uuidString.prefix(8).lowercased())", displayName: "Gate Pilot", chamber: "house", nameAliases: ["Gate Pilot"])
        try await pilot.create(on: db)
        let list = PortfolioList(userId: userId, name: name ?? "Gate Pilot copy \(UUID().uuidString.prefix(4))", mode: "hypothetical")
        try await list.create(on: db)
        let listId = try list.requireID()
        let account = try await PilotAccountResolver.findOrCreate(userId: userId, portfolioId: listId, on: db)
        try await CashBalance(accountId: account.requireID(), currency: "USD", balance: 1000, asOf: Date()).create(on: db)
        let stock = Stock(userId: userId, portfolioListId: listId, symbol: "AAPL", shares: 5, buyPrice: 100, buyDate: Date(), sourceProvider: "pilot")
        try await stock.create(on: db)
        let follow = try PilotFollow(userId: userId, pilotId: pilot.requireID(), targetKind: .portfolio, portfolioListId: listId, startingCapital: 1000)
        try await follow.create(on: db)
        return try FollowedList(listId: listId, follow: follow, pilotAccount: account, stockId: stock.requireID())
    }

    func seedInstrument(symbol: String, on db: any Database) async throws -> Instrument {
        if let existing = try await Instrument.query(on: db).filter(\.$symbol == symbol).first() {
            return existing
        }
        let instrument = Instrument(conid: "gate:\(symbol):\(UUID().uuidString.prefix(6))", symbol: symbol, exchange: "TEST", currency: "USD", name: symbol)
        try await instrument.create(on: db)
        return instrument
    }

    func stockSnapshot(listId: UUID, on db: any Database) async throws -> [String] {
        try await Stock.query(on: db).filter(\.$portfolioListId == listId).all()
            .map { "\($0.symbol):\($0.shares):\($0.sourceProvider ?? "-")" }
            .sorted()
    }
}
