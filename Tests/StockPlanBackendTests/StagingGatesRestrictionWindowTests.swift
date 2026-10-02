import Fluent
import FluentSQL
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// M5: a simulated pilot buy never violates a wash-sale restriction window.
extension StagingGatesTests {
    @Test("a pilot buy never violates a tax restriction window; a real buy still does")
    func pilotBuysNeverViolateRestrictionWindows() async throws {
        try await withApp { app in
            let (_, userId) = try await registerTestUser(app: app)
            let taxYear = Calendar(identifier: .gregorian).component(.year, from: Date())
            let profile = try await app.taxService.saveProfile(userId: userId, request: TaxProfileRequest(
                jurisdiction: .unitedStates, taxYear: taxYear, filingStatus: .single, reportingCurrency: "USD",
                estimatedTaxableIncome: 50000, marginalIncomeTaxRate: 0.3, shortTermCapitalGainsRate: 0.3, longTermCapitalGainsRate: 0.15,
                members: [.init(id: "self", displayName: "You", relationship: "self")], accounts: []
            ), on: app.db)
            let symbol = "RWG\(UUID().uuidString.prefix(4))".uppercased()
            let instrument = try await seedInstrument(symbol: symbol, on: app.db)
            let instrumentId = try instrument.requireID()
            let real = Account(userId: userId, externalId: "gate-real-\(UUID().uuidString)", broker: "manual", displayName: "Real", baseCurrency: "USD")
            real.taxJurisdiction = TaxJurisdiction.unitedStates.rawValue
            try await real.create(on: app.db)
            let seeded = try await seedFollowedList(userId: userId, on: app.db)
            let pilotAccountId = try seeded.pilotAccount.requireID()
            let now = Date()

            // A simulated BUY three days before the harvest sale.
            try await Transaction(accountId: pilotAccountId, instrumentId: instrumentId, externalId: "pilot:\(UUID().uuidString)", type: "BUY", quantity: 2, price: 50, currency: "USD", tradeDate: now.addingTimeInterval(-3 * 86400)).create(on: app.db)

            let scenario = TaxScenario()
            scenario.userId = userId
            scenario.profileId = try #require(UUID(uuidString: profile.id))
            scenario.kind = "harvest"
            scenario.requestJSON = "{}"
            scenario.responseJSON = "{}"
            try await scenario.create(on: app.db)
            let plan = TaxActionPlan()
            plan.userId = userId
            plan.scenarioId = try scenario.requireID()
            plan.kind = "harvest"
            plan.idempotencyKey = UUID().uuidString
            plan.status = TaxActionPlanStatus.accepted.rawValue
            plan.responseJSON = "{}"
            try await plan.create(on: app.db)
            let leg = TaxActionLegRecord()
            leg.actionPlanId = try plan.requireID()
            leg.accountId = try real.requireID()
            leg.instrumentId = instrumentId
            leg.symbol = symbol
            leg.side = TaxLocationLegSide.sell.rawValue
            leg.quantity = 5
            leg.notional = 250
            leg.currency = "USD"
            leg.lotIDsJSON = "[]"
            leg.status = TaxActionLegStatus.planned.rawValue
            try await leg.create(on: app.db)
            let sale = try Transaction(accountId: real.requireID(), instrumentId: instrumentId, externalId: "real-sell:\(UUID().uuidString)", type: "SELL", quantity: 5, price: 50, currency: "USD", tradeDate: now)
            try await sale.create(on: app.db)

            let reconciler = TaxPlanReconciler()
            try await reconciler.complete(
                TaxPlanReconciler.Match(legID: leg.requireID(), planID: plan.requireID(), lotIDs: []),
                transaction: sale, userId: userId, on: app.db
            )
            let window = try #require(try await TaxRestrictionWindow.query(on: app.db).filter(\.$actionLegId == leg.requireID()).first())
            #expect(window.status == "active", "an earlier simulated buy violated the window")

            // A simulated BUY inside the window, arriving later.
            let laterPilotBuy = Transaction(accountId: pilotAccountId, instrumentId: instrumentId, externalId: "pilot:\(UUID().uuidString)", type: "BUY", quantity: 1, price: 50, currency: "USD", tradeDate: now.addingTimeInterval(86400))
            try await laterPilotBuy.create(on: app.db)
            try await reconciler.complete(nil, transaction: laterPilotBuy, userId: userId, on: app.db)
            #expect(try await TaxRestrictionWindow.find(window.requireID(), on: app.db)?.status == "active", "a later simulated buy violated the window")

            // A real BUY still violates it.
            let realBuy = try Transaction(accountId: real.requireID(), instrumentId: instrumentId, externalId: "real-buy:\(UUID().uuidString)", type: "BUY", quantity: 1, price: 50, currency: "USD", tradeDate: now.addingTimeInterval(2 * 86400))
            try await realBuy.create(on: app.db)
            try await reconciler.complete(nil, transaction: realBuy, userId: userId, on: app.db)
            let violated = try #require(try await TaxRestrictionWindow.find(window.requireID(), on: app.db))
            #expect(violated.status == "violated")
            #expect(violated.violatingTransactionId == realBuy.id)

            // TaxService's window (a manually completed plan) shares this query.
            let buys = try await TaxRestrictionPurchases.buys(userId: userId, from: now.addingTimeInterval(-30 * 86400), through: now.addingTimeInterval(30 * 86400), on: app.db)
            #expect(!buys.isEmpty)
            #expect(buys.allSatisfy { $0.accountId != pilotAccountId })
            #expect(buys.contains { $0.id == realBuy.id })
        }
    }
}
