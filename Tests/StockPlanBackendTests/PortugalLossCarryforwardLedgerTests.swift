import Fluent
import Foundation
@testable import StockPlanBackend
import Testing
import Vapor

@Suite("Portugal loss carryforward ledger", .serialized)
struct PortugalLossCarryforwardLedgerTests {
    private let ledger = PortugalLossCarryforwardLedger()

    @Test
    func `consumes oldest balances and repeated reconciliation is idempotent`() async throws {
        try await withApp { app in
            let userId = UUID()
            try await createBalance(userId: userId, year: 2021, amount: 1000, on: app.db)
            try await createBalance(userId: userId, year: 2022, amount: 500, on: app.db)
            let result = capitalGainsResult(balance: 2000, applied: 1200)

            try await ledger.reconcile(
                userId: userId,
                taxYear: 2024,
                currency: "EUR",
                ruleVersion: "PT-2026.2",
                result: result,
                on: app.db
            )
            try await ledger.reconcile(
                userId: userId,
                taxYear: 2024,
                currency: "EUR",
                ruleVersion: "PT-2026.2",
                result: result,
                on: app.db
            )

            let balances = try await TaxLossCarryforward.query(on: app.db)
                .filter(\.$userId == userId)
                .sort(\.$sourceTaxYear)
                .all()
            let sourceIDs = balances.filter { $0.sourceTaxYear < 2024 }.compactMap(\.id)
            let applications = try await TaxLossCarryforwardApplication.query(on: app.db)
                .filter(\.$carryforwardId ~~ sourceIDs)
                .filter(\.$targetTaxYear == 2024)
                .sort(\.$amount, .descending)
                .all()
            #expect(applications.count == 2)
            #expect(applications.map(\.amount) == [1000, 200])
            #expect(try await ledger.available(userId: userId, taxYear: 2025, on: app.db) == 300)
            let response = try await ledger.response(
                userId: userId,
                jurisdiction: .portugal,
                asOfTaxYear: 2025,
                on: app.db
            )
            #expect(response.totalAvailable.amount == 300)
            #expect(response.balances.count(where: { $0.sourceTaxYear < 2024 }) == 2)
            #expect(response.balances.flatMap(\.applications).count == 2)
        }
    }

    @Test
    func `excludes balances after the fifth following tax year`() async throws {
        try await withApp { app in
            let userId = UUID()
            try await createBalance(userId: userId, year: 2018, amount: 900, on: app.db)
            try await createBalance(userId: userId, year: 2019, amount: 400, on: app.db)
            #expect(try await ledger.available(userId: userId, taxYear: 2024, on: app.db) == 400)
        }
    }

    @Test
    func `upserts a recalculated source year without duplicating it`() async throws {
        try await withApp { app in
            let userId = UUID()
            try await ledger.reconcile(
                userId: userId,
                taxYear: 2026,
                currency: "EUR",
                ruleVersion: "PT-2026.2",
                result: capitalGainsResult(balance: -700, applied: 0),
                on: app.db
            )
            try await ledger.reconcile(
                userId: userId,
                taxYear: 2026,
                currency: "EUR",
                ruleVersion: "PT-2026.2",
                result: capitalGainsResult(balance: -500, applied: 0),
                on: app.db
            )
            let balances = try await TaxLossCarryforward.query(on: app.db)
                .filter(\.$userId == userId)
                .filter(\.$sourceTaxYear == 2026)
                .all()
            #expect(balances.count == 1)
            #expect(balances.first?.originalAmount == 500)
            #expect(balances.first?.remainingAmount == 500)
            #expect(balances.first?.expiresAfterTaxYear == 2031)
        }
    }

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
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

    private func createBalance(
        userId: UUID,
        year: Int,
        amount: Double,
        on database: any Database
    ) async throws {
        let balance = TaxLossCarryforward()
        balance.userId = userId
        balance.jurisdiction = "PT"
        balance.sourceTaxYear = year
        balance.expiresAfterTaxYear = year + 5
        balance.originalAmount = amount
        balance.remainingAmount = amount
        balance.currency = "EUR"
        balance.ruleVersion = "PT-2026.2"
        try await balance.create(on: database)
    }

    private func capitalGainsResult(balance: Decimal, applied: Decimal) -> PortugalCapitalGainsResult {
        PortugalCapitalGainsResult(
            annualBalance: balance,
            taxableBalance: max(0, balance - applied),
            appliedLossCarryforward: applied,
            remainingLossCarryforward: 0,
            estimatedTax: 0,
            appliedRate: 0.28,
            aggregationRequired: false,
            aggregationApplied: true
        )
    }
}
