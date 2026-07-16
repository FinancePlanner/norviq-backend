import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Tax jurisdiction completeness")
struct TaxJurisdictionCompletenessTests {
    private let unvalidated = TaxRuleRegistry(validatedJurisdictions: [])
    private let usValidated = TaxRuleRegistry(validatedJurisdictions: [.unitedStates])

    @Test
    func `france and italy stay professional review until rule packs exist`() {
        for jurisdiction in [TaxJurisdiction.france, .italy] {
            let pack = unvalidated.pack(for: jurisdiction)
            #expect(pack.supportLevel(instrumentType: "stock", wrapper: .taxable) == .professionalReview)
            #expect(pack.supportLevel(instrumentType: "etf", wrapper: .taxable) == .professionalReview)
            #expect(pack.rate(isLongTerm: true, profile: profile(jurisdiction: jurisdiction)) == nil)
            #expect(pack.assumptions(taxYear: 2026).contains { $0.contains("not enabled") || $0.contains("rule pack") })
            #expect(pack.ruleVersion.contains("unvalidated"))
        }
    }

    @Test
    func `validated us stock remains supported while unvalidated portugal is estimate only`() {
        #expect(
            usValidated.pack(for: .unitedStates)
                .supportLevel(instrumentType: "stock", wrapper: .taxable) == .supported
        )
        #expect(
            unvalidated.pack(for: .portugal)
                .supportLevel(instrumentType: "stock", wrapper: .taxable) == .estimateOnly
        )
    }

    @Test
    func `spain etf requires professional review without market admission metadata`() {
        #expect(
            unvalidated.pack(for: .spain)
                .supportLevel(instrumentType: "etf", wrapper: .taxable) == .professionalReview
        )
        #expect(
            unvalidated.pack(for: .spain)
                .supportLevel(instrumentType: "stock", wrapper: .taxable) == .estimateOnly
        )
    }

    @Test
    func `capabilities advertise france and italy as professional review for equities`() {
        let capabilities = unvalidated.capabilities(taxYear: 2026)
        let frStock = capabilities.first { $0.jurisdiction == .france && $0.instrumentType == "stock" }
        let itEtf = capabilities.first { $0.jurisdiction == .italy && $0.instrumentType == "etf" }
        #expect(frStock?.supportLevel == .professionalReview)
        #expect(itEtf?.supportLevel == .professionalReview)
        #expect(frStock?.limitations.contains { $0.contains("No production capital-gains") } == true)
    }

    private func profile(jurisdiction: TaxJurisdiction) -> TaxProfileRequest {
        TaxProfileRequest(
            jurisdiction: jurisdiction,
            taxYear: 2026,
            filingStatus: .single,
            reportingCurrency: jurisdiction == .unitedStates ? "USD" : "EUR",
            estimatedTaxableIncome: 50000,
            marginalIncomeTaxRate: 0.3,
            members: [.init(id: "self", displayName: "You", relationship: "self")],
            accounts: []
        )
    }
}
