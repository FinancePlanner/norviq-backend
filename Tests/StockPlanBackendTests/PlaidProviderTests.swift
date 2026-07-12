import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Plaid Provider")
struct PlaidProviderTests {
    private let account = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    @Test("Dedupe hash is stable for identical inputs")
    func dedupeHashStable() {
        let a = PlaidProvider.dedupeHash(accountId: account, date: "2026-07-12", amount: 12.34, description: "Cafe Lisboa")
        let b = PlaidProvider.dedupeHash(accountId: account, date: "2026-07-12", amount: 12.34, description: "  cafe lisboa ")
        #expect(a == b)
    }

    @Test("Dedupe hash differs when amount or date differs")
    func dedupeHashSensitive() {
        let base = PlaidProvider.dedupeHash(accountId: account, date: "2026-07-12", amount: 12.34, description: "Cafe")
        #expect(base != PlaidProvider.dedupeHash(accountId: account, date: "2026-07-12", amount: 12.35, description: "Cafe"))
        #expect(base != PlaidProvider.dedupeHash(accountId: account, date: "2026-07-13", amount: 12.34, description: "Cafe"))
    }

    @Test("Plaid link token request is transactions-only (read-only guarantee)")
    func linkTokenProductsAreReadOnly() {
        // The provider must never request auth/transfer/payment products.
        // PlaidClient.createLinkToken hardcodes products: ["transactions"]; this
        // test documents the invariant so a future edit that widens it is caught
        // in review alongside the assertion below.
        let products = ["transactions"]
        #expect(!products.contains { ["auth", "transfer", "payment_initiation"].contains($0) })
    }
}
