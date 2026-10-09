import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Terminal position records", .serialized)
struct TerminalPositionRecordTests {
    @Test("A stored row round-trips and recomputes its derived fields on read")
    func roundTrip() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let record = TerminalPositionRecord(
                userId: user.userId, ticker: "AMZN", sharesOutstanding: 10_600_000_000,
                terminalShareCount: 11_000_000_000, terminalMarketCap: 10_000_000_000_000,
                valueWanted: 1_000_000, sharesOwned: 750, currentSharePrice: nil, notes: nil, sortOrder: 0
            )
            try await record.save(on: app.db)
            let loaded = try #require(try await TerminalPositionRecord.owned(by: user.userId, on: app.db).first())
            let response = loaded.toResponse()
            #expect(response.ticker == "AMZN")
            #expect(abs((response.sharesNeeded ?? 0) - 1100) < 1e-9)
            #expect(abs((response.progress ?? 0) - 0.681818181818) < 1e-9)
            #expect(response.scenarioError == nil)
        }
    }

    @Test("An invalid scenario is stored and reported, with no derived numbers")
    func invalidScenario() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let record = TerminalPositionRecord(
                userId: user.userId, ticker: "VG", sharesOutstanding: nil, terminalShareCount: 0,
                terminalMarketCap: 12_500_000_000, valueWanted: 500_000, sharesOwned: 0,
                currentSharePrice: nil, notes: nil, sortOrder: 0
            )
            try await record.save(on: app.db)
            let response = record.toResponse()
            #expect(response.scenarioError == "share_count_not_positive")
            #expect(response.sharesNeeded == nil)
            #expect(response.terminalSharePrice == nil)
        }
    }

    @Test("Autobuy rows report their monthly equivalent")
    func autobuy() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let row = AutobuyRecord(
                userId: user.userId, ticker: "AMZN", label: "AMZN", amount: 275, cadence: .bimonthly,
                percent: nil, active: true
            )
            try await row.save(on: app.db)
            #expect(row.toResponse().monthlyEquivalent == 137.5)
            #expect(row.cadenceValue == .bimonthly)
        }
    }
}
