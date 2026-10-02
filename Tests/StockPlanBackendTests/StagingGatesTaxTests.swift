import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

/// G3: a simulated buy never counts as a wash-sale replacement.
extension StagingGatesTests {
    private static let washWarning = "substantially identical acquisition"

    private func lossOpportunityWarnings(_ app: Application, userId: UUID, symbol: String, taxYear: Int) async throws -> [String] {
        let dashboard = try await app.taxService.dashboard(userId: userId, jurisdiction: .unitedStates, taxYear: taxYear, on: app.db)
        let opportunity = try #require(dashboard.opportunities.first { $0.symbol == symbol })
        return opportunity.warnings
    }

    @Test("a simulated buy inside 30 days does not block a real loss harvest; a real buy still does")
    func simulatedBuysAreNotWashSaleReplacements() async throws {
        try await withApp { app in
            let (_, userId) = try await registerTestUser(app: app)
            let taxYear = Calendar(identifier: .gregorian).component(.year, from: Date())
            _ = try await app.taxService.saveProfile(userId: userId, request: TaxProfileRequest(
                jurisdiction: .unitedStates,
                taxYear: taxYear,
                filingStatus: .single,
                reportingCurrency: "USD",
                estimatedTaxableIncome: 50000,
                marginalIncomeTaxRate: 0.3,
                shortTermCapitalGainsRate: 0.3,
                longTermCapitalGainsRate: 0.15,
                members: [.init(id: "self", displayName: "You", relationship: "self")],
                accounts: []
            ), on: app.db)
            let symbol = "WSG\(UUID().uuidString.prefix(4))".uppercased()
            let instrument = try await seedInstrument(symbol: symbol, on: app.db)
            let instrumentId = try instrument.requireID()

            // A real taxable lot sitting at a loss.
            let real = Account(userId: userId, externalId: "gate-real-\(UUID().uuidString)", broker: "manual", displayName: "Real", baseCurrency: "USD")
            real.taxWrapper = "taxable"
            try await real.create(on: app.db)
            let realId = try real.requireID()
            try await Lot(accountId: realId, instrumentId: instrumentId, openDate: Date().addingTimeInterval(-90 * 86400), openQuantity: 10, remainingQuantity: 10, openPrice: 100, currency: "USD", status: "open").create(on: app.db)
            try await Position(accountId: realId, instrumentId: instrumentId, quantity: 10, averageCost: 100, currency: "USD", lastPrice: 50, lastPriceDate: Date()).create(on: app.db)

            // The pilot mirror bought the same instrument three days ago.
            let seeded = try await seedFollowedList(userId: userId, on: app.db)
            try await Transaction(accountId: seeded.pilotAccount.requireID(), instrumentId: instrumentId, externalId: "pilot:\(UUID().uuidString)", type: "buy", quantity: 4, price: 50, currency: "USD", tradeDate: Date().addingTimeInterval(-3 * 86400)).create(on: app.db)

            let simulatedOnly = try await lossOpportunityWarnings(app, userId: userId, symbol: symbol, taxYear: taxYear)
            #expect(!simulatedOnly.contains { $0.contains(Self.washWarning) }, "\(simulatedOnly)")

            // A real buy in another real account still flags the wash sale.
            let other = Account(userId: userId, externalId: "gate-other-\(UUID().uuidString)", broker: "ibkr", displayName: "Other", baseCurrency: "USD")
            try await other.create(on: app.db)
            try await Transaction(accountId: other.requireID(), instrumentId: instrumentId, externalId: "real:\(UUID().uuidString)", type: "BUY", quantity: 1, price: 50, currency: "USD", tradeDate: Date().addingTimeInterval(-3 * 86400)).create(on: app.db)

            let withRealBuy = try await lossOpportunityWarnings(app, userId: userId, symbol: symbol, taxYear: taxYear)
            #expect(withRealBuy.contains { $0.contains(Self.washWarning) }, "\(withRealBuy)")
        }
    }
}
