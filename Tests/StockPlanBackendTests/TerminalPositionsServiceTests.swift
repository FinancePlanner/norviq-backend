import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("Terminal positions service", .serialized)
struct TerminalPositionsServiceTests {
    private let service = TerminalPositionsService()

    private func status(of body: () async throws -> some Any) async -> HTTPResponseStatus? {
        do {
            _ = try await body()
            return nil
        } catch let abort as any AbortError {
            return abort.status
        } catch {
            return .internalServerError
        }
    }

    @Test("Create normalises the ticker and appends to the end")
    func createAppends() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let first = try await service.create(userId: user.userId, TerminalFixtures.amzn(), on: app.db)
            let second = try await service.create(userId: user.userId, TerminalFixtures.vg(), on: app.db)
            #expect(first.ticker == "AMZN")
            #expect(first.sortOrder == 0)
            #expect(second.sortOrder == 1)
        }
    }

    @Test("Bad tickers and negative money are 422; a zero share count is stored with scenarioError")
    func validation() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let badTicker = TerminalPositionCreateRequest(ticker: "  $$ ", terminalShareCount: 1, terminalMarketCap: 1, valueWanted: 1)
            let negative = TerminalPositionCreateRequest(ticker: "VG", terminalShareCount: 1, terminalMarketCap: 1, valueWanted: -1)
            let badTickerStatus = await status { try await service.create(userId: user.userId, badTicker, on: app.db) }
            let negativeStatus = await status { try await service.create(userId: user.userId, negative, on: app.db) }
            #expect(badTickerStatus == .unprocessableEntity)
            #expect(negativeStatus == .unprocessableEntity)

            let zero = TerminalPositionCreateRequest(ticker: "VG", terminalShareCount: 0, terminalMarketCap: 12_500_000_000, valueWanted: 500_000)
            let stored = try await service.create(userId: user.userId, zero, on: app.db)
            #expect(stored.toResponse().scenarioError == "share_count_not_positive")
        }
    }

    @Test("PATCH changes only sent fields; clear nils nullable fields; unknown clear is 422")
    func patchAndClear() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let created = try await service.create(userId: user.userId, TerminalPositionCreateRequest(
                ticker: "AMZN", terminalShareCount: 11_000_000_000, terminalMarketCap: 10_000_000_000_000,
                valueWanted: 1_000_000, currentSharePrice: 200, notes: "base case"
            ), on: app.db)
            let id = try created.requireID()

            let cleared = try await service.update(userId: user.userId, id: id, TerminalPositionUpdateRequest(clear: ["currentSharePrice"]), on: app.db)
            #expect(cleared.currentSharePrice == nil)
            #expect(cleared.notes == "base case")
            #expect(cleared.valueWanted == 1_000_000)

            let changed = try await service.update(userId: user.userId, id: id, TerminalPositionUpdateRequest(valueWanted: 2_000_000), on: app.db)
            #expect(changed.valueWanted == 2_000_000)
            #expect(changed.terminalShareCount == 11_000_000_000)

            let unknown = await status {
                try await service.update(userId: user.userId, id: id, TerminalPositionUpdateRequest(clear: ["valueWanted"]), on: app.db)
            }
            #expect(unknown == .unprocessableEntity)
        }
    }

    @Test("Another user's row is 404 for update, delete and duplicate")
    func scoping() async throws {
        try await TerminalFixtures.withApp { app in
            let owner = try await TerminalFixtures.registerUser(app: app)
            let other = try await TerminalFixtures.registerUser(app: app)
            let row = try await service.create(userId: owner.userId, TerminalFixtures.vg(), on: app.db)
            let id = try row.requireID()
            let update = await status { try await service.update(userId: other.userId, id: id, TerminalPositionUpdateRequest(valueWanted: 1), on: app.db) }
            let delete = await status { try await service.delete(userId: other.userId, id: id, on: app.db) }
            let duplicate = await status { try await service.duplicate(userId: other.userId, id: id, on: app.db) }
            #expect(update == .notFound)
            #expect(delete == .notFound)
            #expect(duplicate == .notFound)
        }
    }

    @Test("Duplicate lands right after its source and shifts later rows")
    func duplicatePlacement() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let a = try await service.create(userId: user.userId, TerminalFixtures.amzn(), on: app.db)
            _ = try await service.create(userId: user.userId, TerminalFixtures.vg(), on: app.db)
            _ = try await service.duplicate(userId: user.userId, id: a.requireID(), on: app.db)
            let rows = try await service.list(userId: user.userId, on: app.db)
            #expect(rows.map(\.ticker) == ["AMZN", "AMZN", "VG"])
            #expect(rows.map(\.sortOrder) == [0, 1, 2])
        }
    }

    @Test("Reorder needs every id exactly once; a bad list changes nothing")
    func reorder() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let a = try await service.create(userId: user.userId, TerminalFixtures.amzn(), on: app.db)
            let b = try await service.create(userId: user.userId, TerminalFixtures.vg(), on: app.db)
            let ids = try [b.requireID().uuidString, a.requireID().uuidString]
            let reordered = try await service.reorder(userId: user.userId, ids: ids, on: app.db)
            #expect(reordered.map(\.ticker) == ["VG", "AMZN"])

            let missing = await status { try await service.reorder(userId: user.userId, ids: [ids[0]], on: app.db) }
            let duplicated = await status { try await service.reorder(userId: user.userId, ids: [ids[0], ids[0]], on: app.db) }
            let foreign = await status { try await service.reorder(userId: user.userId, ids: [ids[0], UUID().uuidString], on: app.db) }
            #expect(missing == .unprocessableEntity)
            #expect(duplicated == .unprocessableEntity)
            #expect(foreign == .unprocessableEntity)
            let after = try await service.list(userId: user.userId, on: app.db)
            #expect(after.map(\.ticker) == ["VG", "AMZN"])
        }
    }

    @Test("Autobuy validation: percent cadence needs a percent in (0, 1]; unknown cadence rejected")
    func autobuyValidation() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let noPercent = await status {
                try await service.createAutobuy(userId: user.userId, AutobuyCreateRequest(label: "401k", amount: 5000, cadence: .percentOfContribution), on: app.db)
            }
            let tooBig = await status {
                try await service.createAutobuy(userId: user.userId, AutobuyCreateRequest(label: "401k", amount: 5000, cadence: .percentOfContribution, percent: 4), on: app.db)
            }
            let unknown = await status {
                try await service.createAutobuy(userId: user.userId, AutobuyCreateRequest(label: "x", amount: 1, cadence: .unknown), on: app.db)
            }
            #expect(noPercent == .unprocessableEntity)
            #expect(tooBig == .unprocessableEntity)
            #expect(unknown == .unprocessableEntity)
            let ok = try await service.createAutobuy(
                userId: user.userId,
                AutobuyCreateRequest(label: "401k Contributions", amount: 5000, cadence: .percentOfContribution, percent: 0.04),
                on: app.db
            )
            #expect(ok.monthlyEquivalent == 200)
        }
    }

    @Test("Summary totals valid rows, prices and active autobuys, in the default portfolio's currency")
    func summary() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let portfolio = try await PortfolioList.query(on: app.db)
                .filter(\.$userId == user.userId).filter(\.$isDefault == true).first()
                ?? PortfolioList(userId: user.userId, name: "Main", isDefault: true)
            portfolio.baseCurrency = "EUR"
            try await portfolio.save(on: app.db)

            _ = try await service.create(userId: user.userId, TerminalPositionCreateRequest(
                ticker: "AMZN", terminalShareCount: 11_000_000_000, terminalMarketCap: 10_000_000_000_000,
                valueWanted: 1_000_000, sharesOwned: 750, currentSharePrice: 200
            ), on: app.db)
            _ = try await service.create(userId: user.userId, TerminalFixtures.vg(), on: app.db)
            _ = try await service.create(userId: user.userId, TerminalPositionCreateRequest(
                ticker: "BAD", terminalShareCount: 0, terminalMarketCap: 1, valueWanted: 99
            ), on: app.db)
            _ = try await service.createAutobuy(userId: user.userId, AutobuyCreateRequest(label: "AMZN", amount: 275, cadence: .bimonthly), on: app.db)
            _ = try await service.createAutobuy(userId: user.userId, AutobuyCreateRequest(label: "Paused", amount: 999, cadence: .monthly, active: false), on: app.db)

            let summary = try await service.summary(userId: user.userId, on: app.db)
            #expect(summary.currency == "EUR")
            #expect(summary.positionCount == 3)
            #expect(summary.totalValueWanted == 1_500_000)
            let expectedGap = 350 * (10_000_000_000_000.0 / 11_000_000_000) + 500_000
            #expect(abs(summary.totalGapValueAtTerminal - expectedGap) < 1e-3)
            #expect(abs((summary.totalCapitalAtTodayPrice ?? 0) - 220_000) < 1e-6)
            #expect(summary.pricedPositionCount == 1)
            #expect(summary.monthlyAutobuyTotal == 137.5)
            #expect(summary.topPositions.map(\.ticker) == ["AMZN", "VG"])
        }
    }

    @Test("upsertScenario updates the first row for a ticker, creates when complete, errors when not")
    func upsert() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let incomplete = await status {
                try await service.upsertScenario(
                    userId: user.userId, ticker: "SOFI",
                    fields: .init(valueWanted: 250_000), on: app.db
                )
            }
            #expect(incomplete == .unprocessableEntity)
            #expect(try await service.list(userId: user.userId, on: app.db).isEmpty)

            let created = try await service.upsertScenario(
                userId: user.userId, ticker: "sofi",
                fields: .init(terminalShareCount: 1_750_000_000, terminalMarketCap: 150_000_000_000, valueWanted: 250_000),
                on: app.db
            )
            let updated = try await service.upsertScenario(
                userId: user.userId, ticker: "SOFI", fields: .init(sharesOwned: 1000), on: app.db
            )
            #expect(try updated.requireID() == created.requireID())
            #expect(abs((updated.toResponse().progress ?? 0) - 0.3428571429) < 1e-9)
        }
    }
}
