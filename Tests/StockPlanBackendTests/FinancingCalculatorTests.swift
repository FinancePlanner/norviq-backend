import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Financing calculator")
struct FinancingCalculatorTests {
    private let budget = FinancingBudgetContext(
        netMonthlyIncome: 4000,
        baselineSpending: 1800,
        plannedSavings: 600,
        existingFinancingPayments: 0
    )

    @Test
    func `zero rate divides financed principal across the term`() throws {
        let offer = FinancingOfferTerms(
            name: "Car",
            purchaseAmount: 42000,
            downPayment: 7000,
            termMonths: 70,
            firstPaymentDate: "2026-08-31",
            nominalAnnualRate: 0
        )
        let request = FinancingSimulationRequest(
            market: .portugal,
            purchaseType: .vehicle,
            currency: "EUR",
            offers: [offer]
        )
        let result = try FinancingCalculator().simulate(request: request, assumptions: .init(), budget: budget).results[0]
        #expect(result.monthlyPayment == 500)
        #expect(result.projections.count == 70)
        #expect(result.totalLoanPayments == 35000)
    }

    @Test
    func `provider quote remains authoritative over effective annual rate`() throws {
        let offer = FinancingOfferTerms(
            name: "Provider quote",
            purchaseAmount: 50000,
            termMonths: 84,
            firstPaymentDate: "2026-08-01",
            quotedMonthlyPayment: 725,
            effectiveAnnualRate: 7.2
        )
        let request = FinancingSimulationRequest(market: .portugal, purchaseType: .vehicle, currency: "EUR", offers: [offer])
        let result = try FinancingCalculator().simulate(request: request, assumptions: .init(), budget: budget).results[0]
        #expect(result.monthlyPayment == 725)
        #expect(result.warnings.contains { $0.contains("quoted payment") })
    }

    @Test
    func `balloon payment is added only to the final installment`() throws {
        let offer = FinancingOfferTerms(
            name: "Balloon",
            purchaseAmount: 30000,
            termMonths: 36,
            firstPaymentDate: "2026-08-01",
            quotedMonthlyPayment: 400,
            balloonPayment: 10000
        )
        let projections = try FinancingCalculator().projections(planId: nil, offer: offer, currency: "EUR")
        #expect(projections.first?.paymentAmount == 400)
        #expect(projections.last?.paymentAmount == 10400)
    }

    @Test
    func `monthly dates remain valid when starting at month end`() throws {
        let offer = FinancingOfferTerms(
            name: "Month end",
            purchaseAmount: 1200,
            termMonths: 3,
            firstPaymentDate: "2027-01-31",
            quotedMonthlyPayment: 400
        )
        let dates = try FinancingCalculator().projections(planId: nil, offer: offer, currency: "EUR").map(\.dueDate)
        #expect(dates == ["2027-01-31", "2027-02-28", "2027-03-31"])
    }

    @Test
    func `cash flow becomes tight when only the safety buffer fails`() {
        let assessment = FinancingPolicyRegistry.assess(
            market: .spain,
            purchaseType: .vehicle,
            candidateMonthlyPayment: 1100,
            assumptions: .init(safetyBufferPercent: 15),
            budget: budget
        )
        #expect(assessment.cashFlowStatus == .tight)
        #expect(assessment.benchmark.sourceURL != nil)
    }

    @Test
    func `US benchmark does not fabricate a universal threshold`() {
        let assessment = FinancingPolicyRegistry.assess(
            market: .unitedStates,
            purchaseType: .home,
            candidateMonthlyPayment: 1000,
            assumptions: .init(grossMonthlyIncome: 6000),
            budget: budget
        )
        #expect(assessment.benchmark.status == .notEvaluated)
        #expect(assessment.benchmark.guidanceMaximum == nil)
    }
}

@Suite("Financing offer extraction")
struct FinancingOfferExtractorTests {
    @Test
    func `extracts localized disclosed terms from public text`() {
        let response = FinancingOfferExtractor.extract(
            text: "Preco 42.000 EUR. Prazo 84 meses. Mensalidade 615,25 EUR. TAEG 6,8%.",
            sourceDomain: "example.pt"
        )
        #expect(response.recognized)
        #expect(response.draft?.termMonths == 84)
        #expect(response.draft?.effectiveAnnualRate == 6.8)
        #expect(response.sourceDomain == "example.pt")
    }

    @Test
    func `returns an unrecognized draft without inventing values`() {
        let response = FinancingOfferExtractor.extract(text: "Configure your purchase online.", sourceDomain: nil)
        #expect(!response.recognized)
        #expect(response.draft == nil)
    }
}
