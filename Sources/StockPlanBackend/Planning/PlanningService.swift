import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Turns the shared planning math into answers, and adds the one thing that needs the server:
/// a readiness probability from the existing retirement Monte Carlo.
struct PlanningService: Sendable {
    let rules: RetirementRuleRegistry

    // MARK: Growth

    func projection(_ request: GrowthProjectionRequest) throws -> GrowthProjectionResponse {
        let result = try PlanningEngine.project(request.assumptions)
        let sensitivity = try request.sensitivityRates
            .map { try PlanningEngine.sensitivity(request.assumptions, rates: $0) }
            ?? PlanningEngine.sensitivity(request.assumptions)

        return GrowthProjectionResponse(
            result: result,
            sensitivity: sensitivity,
            assumptionNotes: growthNotes(request.assumptions)
        )
    }

    // MARK: Retirement

    func retirement(_ request: RetirementPlanningRequest, req: Request) async throws -> RetirementPlanningResponse {
        try request.need.validate()
        try request.plan.validate()

        let projection = try PlanningEngine.project(request.plan)
        let projected = projection.endingValueNominal
        let need = try PlanningEngine.retirementNeed(request.need, projectedPortfolioAtRetirement: projected)
        let lever = try PlanningEngine.lever(need: request.need, plan: request.plan)

        var probability: Double?
        if request.includeProbability != false {
            probability = try await readinessProbability(request, req: req)
        }

        return RetirementPlanningResponse(
            need: need,
            lever: lever,
            projection: projection,
            projectedPortfolioAtRetirement: projected,
            readinessProbability: probability,
            assumptionNotes: retirementNotes(request)
        )
    }

    /// Reuses `RetirementProjectionEngine` rather than sampling again here. It already models
    /// accumulation, decumulation, withdrawal strategies and pension income; running a second
    /// Monte Carlo beside it would be two engines to keep agreeing about the same question.
    ///
    /// The simulation is CPU-bound over thousands of paths, so it runs off the event loop.
    private func readinessProbability(_ request: RetirementPlanningRequest, req: Request) async throws -> Double? {
        let input = Self.retirementPlanInput(from: request)
        let projectionRequest = RetirementProjectionRequest(pathCount: 2000, seed: 42)
        let engine = RetirementProjectionEngine(rules: rules)

        do {
            let projection = try await Task.detached(priority: .userInitiated) {
                try engine.project(portfolioId: nil, input: input, request: projectionRequest)
            }.value
            return projection.summary.readinessProbability
        } catch {
            // A probability is a bonus on top of the deterministic answer, not the answer. If
            // the sampler rejects these inputs the screen should still show the gap and the
            // lever rather than fail outright.
            req.logger.warning("Retirement readiness probability unavailable: \(String(reflecting: error))")
            return nil
        }
    }

    /// Maps the cost-of-life shaped request onto the salary-shaped input the Monte Carlo
    /// engine takes. Annual contributions are the monthly plan times twelve; the starting
    /// balance is the plan's initial amount.
    static func retirementPlanInput(from request: RetirementPlanningRequest) -> RetirementPlanInput {
        let need = request.need
        let plan = request.plan
        let annualSpendingToday = max(0, need.monthlyCostOfLifeToday - need.monthlyOtherIncomeAtRetirement) * 12

        return RetirementPlanInput(
            jurisdiction: .portugal,
            currency: "EUR",
            currentAge: need.currentAge,
            retirementAge: need.retirementAge,
            longevityAge: need.longevityAge,
            annualSalary: 0,
            desiredAnnualSpending: annualSpendingToday,
            inflationRate: need.annualInflationRate,
            expectedAnnualReturn: plan.annualReturnRate,
            annualVolatility: request.annualVolatility ?? 0.16,
            annualContributionGrowthRate: plan.annualContributionGrowthRate,
            withdrawalStrategy: .fixedRealSpending,
            withdrawalRate: need.withdrawalRate,
            accounts: [
                RetirementAccountPlan(
                    id: UUID().uuidString,
                    name: "Plan",
                    wrapper: .taxable,
                    currentBalance: max(0, plan.initialAmount),
                    employeeAnnualContribution: max(0, plan.monthlyContribution) * 12
                ),
            ]
        )
    }

    // MARK: Assumptions, stated in plain language

    private func growthNotes(_ assumptions: ProjectionAssumptions) -> [String] {
        var notes = [
            "Returns are assumed steady at \(percent(assumptions.annualReturnRate)) a year, compounded monthly. Real markets are not steady.",
            "Contributions are made at the end of each month.",
            "Inflation is assumed at \(percent(assumptions.annualInflationRate)) a year; today's-money figures are the nominal ones divided by it.",
        ]
        if assumptions.annualContributionGrowthRate != 0 {
            notes.append("Contributions rise \(percent(assumptions.annualContributionGrowthRate)) once a year, starting after the first year.")
        }
        notes.append("Projections, not advice.")
        return notes
    }

    private func retirementNotes(_ request: RetirementPlanningRequest) -> [String] {
        var notes = [
            "Today's cost of life is carried forward to retirement at \(percent(request.need.annualInflationRate)) inflation a year.",
            "The headline target is annual spending divided by a \(percent(request.need.withdrawalRate)) withdrawal rate.",
            "The runway comes from spending the money down year by year, which is the figure to trust when the two disagree.",
        ]
        if let ends = request.need.housingEndsAtAge {
            notes.append("Housing is assumed to stop costing anything from age \(ends).")
        }
        if request.includeProbability != false {
            notes.append("The readiness probability samples returns around \(percent(request.need.expectedAnnualReturn)) with \(percent(request.annualVolatility ?? 0.16)) volatility.")
        }
        notes.append("Projections, not advice.")
        return notes
    }

    /// Rates are stored as fractions but read as percentages, and a note saying "7%" reads
    /// better than one saying "7.0%".
    private func percent(_ value: Double) -> String {
        let scaled = ((value * 100) * 100).rounded() / 100
        let text = scaled == scaled.rounded() ? String(Int(scaled)) : String(scaled)
        return "\(text)%"
    }
}
