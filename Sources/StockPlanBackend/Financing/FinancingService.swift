import Fluent
import Foundation
import StockPlanShared
import Vapor

struct FinancingService: Sendable {
    private let calculator = FinancingCalculator()

    func forecastBudgetContext(userId: UUID, on db: any Database) async throws -> FinancingBudgetContext {
        let stored = try await assumptions(userId: userId, on: db)
        return try await budgetContext(userId: userId, assumptions: stored, on: db)
    }

    func simulation(userId: UUID, request: FinancingSimulationRequest, on db: any Database) async throws -> FinancingSimulationResponse {
        let stored = try await assumptions(userId: userId, on: db)
        let applied = request.assumptions ?? stored
        let budget = try await budgetContext(userId: userId, assumptions: applied, on: db)
        return try calculator.simulate(request: request, assumptions: applied, budget: budget)
    }

    func assumptions(userId: UUID, on db: any Database) async throws -> FinancingAffordabilityAssumptions {
        try await FinancingAssumptionsRecord.query(on: db)
            .filter(\.$user.$id == userId)
            .first()?.response ?? .init()
    }

    func updateAssumptions(userId: UUID, value: FinancingAffordabilityAssumptions, on db: any Database) async throws -> FinancingAffordabilityAssumptions {
        guard value.externalMonthlyDebtPayments >= 0,
              (0 ... 30).contains(value.safetyBufferPercent),
              (value.grossMonthlyIncome ?? 0) >= 0,
              (value.netMonthlyIncomeOverride ?? 0) >= 0
        else { throw Abort(.badRequest, reason: "Invalid affordability assumptions.") }
        if let existing = try await FinancingAssumptionsRecord.query(on: db).filter(\.$user.$id == userId).first() {
            existing.apply(value)
            try await existing.update(on: db)
        } else {
            try await FinancingAssumptionsRecord(userId: userId, assumptions: value).create(on: db)
        }
        return value
    }

    func createPlan(userId: UUID, request: FinancingPlanRequest, on db: any Database) async throws -> FinancingPlanResponse {
        try validate(request)
        return try await db.transaction { transaction in
            let plan = FinancingPlan(userId: userId, request: request)
            try await plan.create(on: transaction)
            let planId = try plan.requireID()
            try await FinancingPlanRevision(planId: planId, effectiveInstallment: 1, terms: request.terms).create(on: transaction)
            return response(plan: plan, terms: request.terms)
        }
    }

    func plans(userId: UUID, on db: any Database) async throws -> [FinancingPlanResponse] {
        let plans = try await FinancingPlan.query(on: db)
            .filter(\.$user.$id == userId)
            .sort(\.$createdAt, .descending)
            .all()
        var result: [FinancingPlanResponse] = []
        for plan in plans {
            guard let terms = try await latestRevision(planId: plan.requireID(), on: db)?.terms else { continue }
            result.append(response(plan: plan, terms: terms))
        }
        return result
    }

    func plan(userId: UUID, planId: UUID, on db: any Database) async throws -> FinancingPlan {
        guard let plan = try await FinancingPlan.query(on: db)
            .filter(\.$id == planId)
            .filter(\.$user.$id == userId)
            .first()
        else { throw Abort(.notFound) }
        return plan
    }

    func updateStatus(userId: UUID, planId: UUID, status: FinancingPlanStatus, on db: any Database) async throws -> FinancingPlanResponse {
        let plan = try await plan(userId: userId, planId: planId, on: db)
        plan.status = status.rawValue
        try await plan.update(on: db)
        guard let terms = try await latestRevision(planId: planId, on: db)?.terms else { throw Abort(.notFound) }
        return response(plan: plan, terms: terms)
    }

    func revise(userId: UUID, planId: UUID, request: FinancingPlanRevisionRequest, on db: any Database) async throws -> FinancingPlanResponse {
        let plan = try await plan(userId: userId, planId: planId, on: db)
        try validateTerms(request.terms)
        let lastMatch = try await FinancingExpenseMatch.query(on: db)
            .filter(\.$plan.$id == planId)
            .sort(\.$installmentNumber, .descending)
            .first()?.installmentNumber ?? 0
        let lastRevision = try await latestRevision(planId: planId, on: db)?.effectiveInstallment ?? 1
        let effective = max(lastMatch + 1, lastRevision + 1)
        try await FinancingPlanRevision(planId: planId, effectiveInstallment: effective, terms: request.terms).create(on: db)
        return response(plan: plan, terms: request.terms)
    }

    func schedule(userId: UUID, planId: UUID, on db: any Database) async throws -> [FinancingProjectionResponse] {
        let plan = try await plan(userId: userId, planId: planId, on: db)
        guard let revision = try await latestRevision(planId: planId, on: db) else { throw Abort(.notFound) }
        let matches = try await FinancingExpenseMatch.query(on: db).filter(\.$plan.$id == planId).all()
        let byInstallment = Dictionary(uniqueKeysWithValues: matches.map { match in
            (match.installmentNumber, match.$expense.id.uuidString)
        })
        var projections = try calculator.projections(planId: planId.uuidString, offer: revision.terms, currency: plan.currency, matched: byInstallment)
        if plan.status == FinancingPlanStatus.cancelled.rawValue {
            projections = projections.map { item in
                guard item.status != .matched else { return item }
                return .init(planId: item.planId, offerId: item.offerId, installmentNumber: item.installmentNumber, dueDate: item.dueDate, paymentAmount: item.paymentAmount, additionalCostAmount: item.additionalCostAmount, totalAmount: item.totalAmount, currency: item.currency, status: .cancelled, matchedExpenseId: item.matchedExpenseId)
            }
        }
        return projections
    }

    func projections(userId: UUID, from: Date?, to: Date?, on db: any Database) async throws -> [FinancingProjectionResponse] {
        let plans = try await FinancingPlan.query(on: db)
            .filter(\.$user.$id == userId)
            .filter(\.$status != FinancingPlanStatus.cancelled.rawValue)
            .all()
        var result: [FinancingProjectionResponse] = []
        for plan in plans {
            let planId = try plan.requireID()
            let schedule = try await schedule(userId: userId, planId: planId, on: db)
            result.append(contentsOf: schedule.filter { item in
                guard let date = FinancingCalculator.dayFormatter.date(from: item.dueDate) else { return false }
                return (from == nil || date >= from!) && (to == nil || date <= to!)
            })
        }
        return result.sorted { $0.dueDate < $1.dueDate }
    }

    func match(userId: UUID, planId: UUID, installment: Int, expenseId: UUID, on db: any Database) async throws -> FinancingExpenseMatchResponse {
        _ = try await plan(userId: userId, planId: planId, on: db)
        guard installment > 0,
              let expense = try await Expense.query(on: db)
              .filter(\.$id == expenseId)
              .filter(\.$user.$id == userId)
              .first()
        else { throw Abort(.notFound) }
        let record = try FinancingExpenseMatch(planId: planId, installmentNumber: installment, expenseId: expense.requireID())
        try await record.create(on: db)
        return try .init(id: record.requireID().uuidString, planId: planId.uuidString, installmentNumber: installment, expenseId: expenseId.uuidString, createdAt: FinancingCalculator.timestamp(record.createdAt))
    }

    func matchCandidates(userId: UUID, expenseId: UUID, on db: any Database) async throws -> [FinancingMatchCandidateResponse] {
        guard let expense = try await Expense.query(on: db)
            .filter(\.$id == expenseId)
            .filter(\.$user.$id == userId)
            .first()
        else { throw Abort(.notFound) }
        let plans = try await FinancingPlan.query(on: db)
            .filter(\.$user.$id == userId)
            .filter(\.$status == FinancingPlanStatus.active.rawValue)
            .all()
        var result: [FinancingMatchCandidateResponse] = []
        let calendar = Calendar(identifier: .gregorian)
        for plan in plans {
            let planId = try plan.requireID()
            for projection in try await schedule(userId: userId, planId: planId, on: db) where projection.status != .matched {
                guard let dueDate = FinancingCalculator.dayFormatter.date(from: projection.dueDate) else { continue }
                let expected = projection.totalAmount * plan.userSharePercent / 100
                let amountDelta = abs(expense.amount - expected)
                let amountTolerance = max(1, expected * 0.02)
                let dayDelta = abs(calendar.dateComponents([.day], from: dueDate, to: expense.occurredOn).day ?? 999)
                var score = 0.0
                var reasons: [String] = []
                if amountDelta <= amountTolerance {
                    score += 0.6; reasons.append("amount")
                }
                if dayDelta <= 7 {
                    score += 0.3; reasons.append("date")
                }
                if expense.title.localizedCaseInsensitiveContains(plan.title) || plan.title.localizedCaseInsensitiveContains(expense.title) {
                    score += 0.1; reasons.append("title")
                }
                if score >= 0.5 {
                    result.append(.init(planId: planId.uuidString, planTitle: plan.title, installmentNumber: projection.installmentNumber, dueDate: projection.dueDate, expenseId: expenseId.uuidString, score: score, reasons: reasons))
                }
            }
        }
        return result.sorted { $0.score > $1.score }
    }

    func unmatch(userId: UUID, planId: UUID, installment: Int, on db: any Database) async throws {
        _ = try await plan(userId: userId, planId: planId, on: db)
        guard let record = try await FinancingExpenseMatch.query(on: db)
            .filter(\.$plan.$id == planId)
            .filter(\.$installmentNumber == installment)
            .first()
        else { throw Abort(.notFound) }
        try await record.delete(on: db)
    }

    private func budgetContext(userId: UUID, assumptions: FinancingAffordabilityAssumptions, on db: any Database) async throws -> FinancingBudgetContext {
        let snapshot = try await BudgetSnapshot.query(on: db)
            .filter(\.$user.$id == userId)
            .sort(\.$monthStart, .descending)
            .first()
        var baseline = 0.0
        var plannedSavings = 0.0
        if let snapshot, let snapshotId = snapshot.id {
            let items = try await BudgetPlanItem.query(on: db).filter(\.$snapshot.$id == snapshotId).all()
            for item in items {
                let userAmount = item.plannedAmount * item.userSharePercent / 100
                if item.pillar == .futureYou {
                    plannedSavings += userAmount
                } else {
                    baseline += userAmount
                }
            }
            plannedSavings = max(plannedSavings, snapshot.netSalary * (snapshot.targetShares[BudgetPillar.futureYou.rawValue] ?? 0))
        }
        let active = try await FinancingPlan.query(on: db)
            .filter(\.$user.$id == userId)
            .filter(\.$status == FinancingPlanStatus.active.rawValue)
            .all()
        var existing = 0.0
        for plan in active {
            if let revision = try await latestRevision(planId: plan.requireID(), on: db) {
                let items = try calculator.projections(planId: nil, offer: revision.terms, currency: plan.currency)
                existing += (items.map(\.totalAmount).max() ?? 0) * plan.userSharePercent / 100
            }
        }
        return .init(
            netMonthlyIncome: assumptions.netMonthlyIncomeOverride ?? snapshot?.netSalary,
            baselineSpending: baseline,
            plannedSavings: plannedSavings,
            existingFinancingPayments: existing
        )
    }

    private func latestRevision(planId: UUID, on db: any Database) async throws -> FinancingPlanRevision? {
        try await FinancingPlanRevision.query(on: db)
            .filter(\.$plan.$id == planId)
            .sort(\.$effectiveInstallment, .descending)
            .first()
    }

    private func response(plan: FinancingPlan, terms: FinancingOfferTerms) -> FinancingPlanResponse {
        .init(
            id: plan.id?.uuidString ?? "",
            title: plan.title,
            market: FinancingMarket(rawValue: plan.market) ?? .portugal,
            purchaseType: FinancingPurchaseType(rawValue: plan.purchaseType) ?? .other,
            currency: plan.currency,
            status: FinancingPlanStatus(rawValue: plan.status) ?? .active,
            userSharePercent: plan.userSharePercent,
            terms: terms,
            sourceDomain: plan.sourceDomain,
            createdAt: FinancingCalculator.timestamp(plan.createdAt),
            updatedAt: FinancingCalculator.timestamp(plan.updatedAt)
        )
    }

    private func validate(_ request: FinancingPlanRequest) throws {
        guard !request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.currency.uppercased() == request.market.defaultCurrency,
              (0 ... 100).contains(request.userSharePercent)
        else { throw Abort(.badRequest, reason: "Invalid financing plan.") }
        try validateTerms(request.terms)
    }

    private func validateTerms(_ terms: FinancingOfferTerms) throws {
        guard (1 ... 480).contains(terms.termMonths), terms.purchaseAmount > 0, terms.downPayment >= 0 else {
            throw Abort(.badRequest, reason: "Invalid financing terms.")
        }
        _ = try calculator.projections(planId: nil, offer: terms, currency: "EUR")
    }
}
