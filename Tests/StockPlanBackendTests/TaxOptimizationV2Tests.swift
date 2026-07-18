import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Tax optimization V2")
struct TaxOptimizationV2Tests {
    @Test
    func `replacement score uses documented deterministic weights`() throws {
        let result = try TaxReplacementScorer().score(.init(
            correlation: Decimal(string: "0.90"),
            volatilitySimilarity: Decimal(string: "0.80"),
            allocationFit: #require(Decimal(string: "0.70")),
            expenseEfficiency: #require(Decimal(string: "0.60")),
            overlappingReturns: 126
        ))

        #expect(result.score == Decimal(string: "0.80"))
        #expect(result.confidence == Decimal(string: "0.90"))
    }

    @Test
    func `short history lowers confidence without changing rank score`() {
        let result = TaxReplacementScorer().score(.init(
            correlation: nil,
            volatilitySimilarity: nil,
            allocationFit: 1,
            expenseEfficiency: 1,
            overlappingReturns: 40
        ))

        #expect(result.score == Decimal(string: "0.675"))
        #expect(result.confidence == Decimal(string: "0.55"))
    }

    @Test
    func `unreviewed replacement catalog is rejected`() {
        let catalog = TaxOptimizationCatalog(
            replacements: .init(
                version: "test",
                effectiveFrom: "2026-01-01",
                entries: [.init(
                    sourceSymbols: ["AAA"],
                    sourceTaxIdentityGroup: nil,
                    replacementSymbol: "BBB",
                    replacementName: "Beta Fund",
                    replacementExchange: "ARCA",
                    replacementCurrency: "USD",
                    replacementInstrumentType: "etf",
                    eligibleJurisdictions: [.unitedStates],
                    expenseRatio: nil,
                    priority: 1,
                    reviewedAt: "",
                    reviewReference: ""
                )]
            ),
            efficiency: .init(version: "test", effectiveFrom: "2026-01-01", entries: [])
        )

        #expect(throws: TaxOptimizationCatalogError.self) {
            try catalog.validate()
        }
    }

    @Test
    func `bundled production catalog validates`() throws {
        let catalog = try TaxOptimizationCatalog.bundled()

        #expect(catalog.replacements.version.isEmpty == false)
        #expect(catalog.efficiency.entries.isEmpty == false)
    }

    @Test
    func `bundled replacement pairs are reviewed distinct and US only`() throws {
        let entries = try TaxOptimizationCatalog.bundled().replacements.entries

        #expect(entries.isEmpty == false)
        for entry in entries {
            #expect(entry.sourceSymbols.contains(entry.replacementSymbol) == false)
            #expect(entry.replacementName.isEmpty == false)
            #expect(entry.replacementExchange.isEmpty == false)
            #expect(entry.replacementCurrency == "USD")
            #expect(entry.replacementInstrumentType == "etf")
            #expect(entry.eligibleJurisdictions == [.unitedStates])
            #expect(entry.reviewReference.contains("irs.gov/publications/p550"))
            #expect(entry.reviewReference.contains("http"))
        }
    }
}
