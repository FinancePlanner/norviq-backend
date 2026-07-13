import StockPlanShared

enum FinancingPolicyRegistry {
    private struct Policy {
        let maximum: Double?
        let minimum: Double?
        let incomeBasis: String?
        let homeOnly: Bool
        let source: String?
        let reviewedAt: String
        let message: String
    }

    private static let policies: [FinancingMarket: Policy] = [
        .portugal: .init(maximum: 50, minimum: nil, incomeBasis: "net", homeOnly: false, source: "https://clientebancario.bportugal.pt/en/creditworthiness-assessment", reviewedAt: "2026-07-13", message: "Banco de Portugal generally recommends total debt service at or below 50% of net income."),
        .france: .init(maximum: 35, minimum: nil, incomeBasis: "net_before_income_tax", homeOnly: true, source: "https://www.economie.gouv.fr/hcsf-en/measures/measure-relating-granting-mortgages", reviewedAt: "2026-07-13", message: "French mortgage guidance uses a 35% effort ratio, with limited lender flexibility."),
        .spain: .init(maximum: 40, minimum: nil, incomeBasis: "net", homeOnly: false, source: "https://clientebancario.bde.es/pcb/en/menu-horizontal/podemosayudarte/consultasreclama/consultasreclama/", reviewedAt: "2026-07-13", message: "Banco de Espana recommends keeping total debt payments within 40% of net income."),
        .italy: .init(maximum: 33.33, minimum: nil, incomeBasis: "disposable", homeOnly: true, source: "https://economiapertutti.bancaditalia.it/strumenti/calcolatori/calcolatore-della-rata-del-mutuo/", reviewedAt: "2026-07-13", message: "Bank of Italy educational guidance suggests a mortgage payment no higher than about one-third of disposable income."),
        .poland: .init(maximum: 50, minimum: 40, incomeBasis: "net", homeOnly: true, source: "https://www.knf.gov.pl/knf/pl/komponenty/img/nowelizacja_rekomendacja_s_23-07-2020_70340.pdf", reviewedAt: "2026-07-13", message: "Polish mortgage supervision identifies a 40-50% DStI caution band depending on income."),
        .brazil: .init(maximum: 30, minimum: nil, incomeBasis: "gross", homeOnly: true, source: "https://www.bcb.gov.br/meubc/faqs/p/renda-necessaria-para-financiar-um-imovel", reviewedAt: "2026-07-13", message: "Brazilian housing guidance commonly limits payments to about 30% of gross household income."),
        .netherlands: .init(maximum: nil, minimum: nil, incomeBasis: "annual_lookup", homeOnly: true, source: "https://www.afm.nl/en/consumenten/themas/hypotheken/hypotheek-betalen", reviewedAt: "2026-07-13", message: "Dutch mortgage capacity uses annually updated income-and-rate tables; Norviq shows cash-flow feedback but does not reproduce lender underwriting."),
        .germany: .init(maximum: nil, minimum: nil, incomeBasis: nil, homeOnly: false, source: nil, reviewedAt: "2026-07-13", message: "Germany has no single universal consumer DTI threshold; lender policies vary."),
        .unitedStates: .init(maximum: nil, minimum: nil, incomeBasis: "gross", homeOnly: false, source: "https://www.consumerfinance.gov/rules-policy/regulations/1026/43/", reviewedAt: "2026-07-13", message: "US lenders consider DTI or residual income, but current federal rules do not prescribe one universal threshold."),
    ]

    static func assess(
        market: FinancingMarket,
        purchaseType: FinancingPurchaseType,
        candidateMonthlyPayment: Double,
        assumptions: FinancingAffordabilityAssumptions,
        budget: FinancingBudgetContext
    ) -> FinancingAffordabilityAssessment {
        let income = assumptions.netMonthlyIncomeOverride ?? budget.netMonthlyIncome
        let safetyBuffer = (income ?? 0) * assumptions.safetyBufferPercent / 100
        let monthlyFinancing = budget.existingFinancingPayments + candidateMonthlyPayment
        let savings = assumptions.monthlySavingsTargetOverride ?? budget.plannedSavings
        let residual = income.map { $0 - budget.baselineSpending - savings - monthlyFinancing }
        let stressed = income.map { $0 * 0.9 - budget.baselineSpending - savings - monthlyFinancing }

        let cashFlowStatus: FinancingCashFlowStatus
        let message: String
        if income == nil || income == 0 {
            cashFlowStatus = .insufficientData
            message = "Add monthly income to receive affordability feedback."
        } else if (residual ?? 0) < 0 {
            cashFlowStatus = .notDoable
            message = "This plan would reduce the current savings objective or create a monthly shortfall."
        } else if (residual ?? 0) < safetyBuffer || (stressed ?? 0) < 0 {
            cashFlowStatus = .tight
            message = "The base plan fits, but it does not preserve the selected safety margin under stress."
        } else {
            cashFlowStatus = .doable
            message = "The plan preserves the current spending baseline, savings objective, and safety buffer."
        }

        let policy = policies[market]!
        let benchmarkIncome: Double? = policy.incomeBasis == "gross" ? assumptions.grossMonthlyIncome : income
        let debts = assumptions.externalMonthlyDebtPayments + monthlyFinancing
        let ratio = benchmarkIncome.flatMap { $0 > 0 ? debts / $0 * 100 : nil }
        let applicable = !policy.homeOnly || purchaseType == .home
        let benchmarkStatus: FinancingBenchmarkStatus = if !applicable || policy.maximum == nil || ratio == nil {
            .notEvaluated
        } else if ratio! > policy.maximum! {
            .aboveGuidance
        } else {
            .pass
        }
        let benchmark = FinancingBenchmarkResult(
            status: benchmarkStatus,
            ratio: ratio.map { ($0 * 100).rounded() / 100 },
            guidanceMinimum: policy.minimum,
            guidanceMaximum: policy.maximum,
            incomeBasis: policy.incomeBasis,
            sourceURL: policy.source,
            reviewedAt: policy.reviewedAt,
            message: policy.message
        )
        return .init(
            cashFlowStatus: cashFlowStatus,
            benchmark: benchmark,
            monthlyIncome: income,
            baselineSpending: budget.baselineSpending,
            savingsTarget: savings,
            safetyBuffer: FinancingCalculator.money(safetyBuffer),
            monthlyFinancing: FinancingCalculator.money(monthlyFinancing),
            residualAfterPlan: residual.map(FinancingCalculator.money),
            stressedResidual: stressed.map(FinancingCalculator.money),
            message: message
        )
    }
}
