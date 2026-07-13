import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Portugal tax rule pack")
struct PortugalTaxRulePackTests {
    private let pack = TaxRuleRegistry(validatedJurisdictions: [.portugal]).pack(for: .portugal)

    @Test
    func `uses autonomous rate for ordinary securities gains`() {
        #expect(pack.rate(isLongTerm: true, profile: profile(income: 50000, marginalRate: 0.35)) == 0.28)
        #expect(pack.rate(isLongTerm: false, profile: profile(income: 50000, marginalRate: 0.35)) == 0.28)
    }

    @Test
    func `uses entered marginal rate for mandatory short term aggregation`() {
        #expect(pack.rate(isLongTerm: false, profile: profile(income: 86634, marginalRate: 0.48)) == 0.48)
        #expect(pack.rate(isLongTerm: true, profile: profile(income: 86634, marginalRate: 0.48)) == 0.28)
    }

    @Test
    func `remains estimate only until annual netting is modeled`() {
        #expect(pack.supportLevel(instrumentType: "stock", wrapper: .taxable) == .estimateOnly)
        #expect(pack.supportLevel(instrumentType: "option", wrapper: .taxable) == .professionalReview)
        #expect(pack.assumptions(taxYear: 2026).contains { $0.contains("Article 43") })
    }

    private func profile(income: Decimal, marginalRate: Decimal) -> TaxProfileRequest {
        TaxProfileRequest(
            jurisdiction: .portugal,
            taxYear: 2026,
            filingStatus: .single,
            reportingCurrency: "EUR",
            estimatedTaxableIncome: income,
            marginalIncomeTaxRate: marginalRate,
            members: [.init(id: "self", displayName: "You", relationship: "self")],
            accounts: []
        )
    }
}
