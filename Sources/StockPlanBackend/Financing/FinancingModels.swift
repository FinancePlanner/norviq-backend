import Fluent
import Foundation
import StockPlanShared

final class FinancingPlan: Model, @unchecked Sendable {
    static let schema = "financing_plans"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "title") var title: String
    @Field(key: "market") var market: String
    @Field(key: "purchase_type") var purchaseType: String
    @Field(key: "currency") var currency: String
    @Field(key: "status") var status: String
    @Field(key: "user_share_percent") var userSharePercent: Double
    @OptionalField(key: "source_domain") var sourceDomain: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(userId: UUID, request: FinancingPlanRequest) {
        $user.id = userId
        title = request.title
        market = request.market.rawValue
        purchaseType = request.purchaseType.rawValue
        currency = request.currency.uppercased()
        status = FinancingPlanStatus.active.rawValue
        userSharePercent = request.userSharePercent
        sourceDomain = request.sourceDomain
    }
}

final class FinancingPlanRevision: Model, @unchecked Sendable {
    static let schema = "financing_plan_revisions"

    @ID(key: .id) var id: UUID?
    @Parent(key: "plan_id") var plan: FinancingPlan
    @Field(key: "effective_installment") var effectiveInstallment: Int
    @Field(key: "terms") var terms: FinancingOfferTerms
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(planId: UUID, effectiveInstallment: Int, terms: FinancingOfferTerms) {
        $plan.id = planId
        self.effectiveInstallment = effectiveInstallment
        self.terms = terms
    }
}

final class FinancingExpenseMatch: Model, @unchecked Sendable {
    static let schema = "financing_expense_matches"

    @ID(key: .id) var id: UUID?
    @Parent(key: "plan_id") var plan: FinancingPlan
    @Field(key: "installment_number") var installmentNumber: Int
    @Parent(key: "expense_id") var expense: Expense
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(planId: UUID, installmentNumber: Int, expenseId: UUID) {
        $plan.id = planId
        self.installmentNumber = installmentNumber
        $expense.id = expenseId
    }
}

final class FinancingAssumptionsRecord: Model, @unchecked Sendable {
    static let schema = "financing_affordability_assumptions"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "income_scope") var incomeScope: String
    @OptionalField(key: "net_monthly_income_override") var netMonthlyIncomeOverride: Double?
    @OptionalField(key: "gross_monthly_income") var grossMonthlyIncome: Double?
    @Field(key: "external_monthly_debt_payments") var externalMonthlyDebtPayments: Double
    @Field(key: "safety_buffer_percent") var safetyBufferPercent: Double
    @OptionalField(key: "monthly_savings_target_override") var monthlySavingsTargetOverride: Double?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(userId: UUID, assumptions: FinancingAffordabilityAssumptions) {
        $user.id = userId
        apply(assumptions)
    }

    func apply(_ assumptions: FinancingAffordabilityAssumptions) {
        incomeScope = assumptions.incomeScope.rawValue
        netMonthlyIncomeOverride = assumptions.netMonthlyIncomeOverride
        grossMonthlyIncome = assumptions.grossMonthlyIncome
        externalMonthlyDebtPayments = assumptions.externalMonthlyDebtPayments
        safetyBufferPercent = assumptions.safetyBufferPercent
        monthlySavingsTargetOverride = assumptions.monthlySavingsTargetOverride
    }

    var response: FinancingAffordabilityAssumptions {
        .init(
            incomeScope: FinancingIncomeScope(rawValue: incomeScope) ?? .personal,
            netMonthlyIncomeOverride: netMonthlyIncomeOverride,
            grossMonthlyIncome: grossMonthlyIncome,
            externalMonthlyDebtPayments: externalMonthlyDebtPayments,
            safetyBufferPercent: safetyBufferPercent,
            monthlySavingsTargetOverride: monthlySavingsTargetOverride
        )
    }
}
