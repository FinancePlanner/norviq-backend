import Foundation
import StockPlanShared
import Vapor

struct RetirementProjectionEngine: Sendable {
    let rules: RetirementRuleRegistry

    func project(
        portfolioId: UUID,
        input: RetirementPlanInput,
        request: RetirementProjectionRequest
    ) throws -> RetirementProjection {
        try validate(input: input, request: request)
        guard let rulePack = rules.rulePack(jurisdiction: input.jurisdiction, version: request.ruleVersion) else {
            throw Abort(.notFound, reason: "Retirement rule version not found.")
        }

        let years = input.longevityAge - input.currentAge
        var samples = Array(repeating: [Double](), count: years + 1)
        samples.indices.forEach { samples[$0].reserveCapacity(request.pathCount) }
        var successCount = 0
        var shortfallAges = [Int]()

        for path in 0 ..< request.pathCount {
            var random = SplitMix64(seed: request.seed &+ UInt64(path &* 7919))
            var balance = input.accounts.reduce(0) { $0 + max(0, $1.currentBalance) }
            var salary = input.annualSalary
            var contribution = annualContribution(input: input, salary: salary)
            var spending = input.desiredAnnualSpending
            var firstShortfall: Int?
            samples[0].append(balance)

            for offset in 1 ... years {
                let age = input.currentAge + offset
                let returnRate = normal(
                    mean: input.expectedAnnualReturn,
                    standardDeviation: input.annualVolatility,
                    random: &random
                )
                balance = max(0, balance * (1 + returnRate))

                if age < input.retirementAge {
                    balance += contribution
                    salary *= 1 + input.annualSalaryGrowthRate
                    contribution *= 1 + input.annualContributionGrowthRate
                } else {
                    let pension = pensionIncome(input.publicPension, age: age)
                        + input.otherAnnualRetirementIncome
                    let withdrawal = withdrawal(input: input, balance: balance, spending: spending)
                    balance = max(0, balance - max(0, withdrawal - pension))
                    spending *= 1 + input.inflationRate
                    if balance <= 0, firstShortfall == nil {
                        firstShortfall = age
                    }
                }
                samples[offset].append(balance)
            }
            if balance > 0 {
                successCount += 1
            }
            if let firstShortfall {
                shortfallAges.append(firstShortfall)
            }
        }

        let calendarYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        let points = samples.indices.map { index in
            let age = input.currentAge + index
            let sorted = samples[index].sorted()
            let contribution = age < input.retirementAge
                ? annualContribution(input: input, salary: input.annualSalary * pow(1 + input.annualSalaryGrowthRate, Double(index)))
                : 0
            let pension = pensionIncome(input.publicPension, age: age) + (age >= input.retirementAge ? input.otherAnnualRetirementIncome : 0)
            let median = percentile(sorted, 0.50)
            return RetirementProjectionPoint(
                age: age,
                year: calendarYear + index,
                phase: age < input.retirementAge ? .accumulation : .retirement,
                p10: percentile(sorted, 0.10),
                p25: percentile(sorted, 0.25),
                p50: median,
                p75: percentile(sorted, 0.75),
                p90: percentile(sorted, 0.90),
                annualContribution: contribution,
                annualWithdrawal: age >= input.retirementAge ? withdrawal(input: input, balance: median, spending: input.desiredAnnualSpending) : 0,
                annualPensionIncome: pension
            )
        }
        let retirementIndex = input.retirementAge - input.currentAge
        let headroom = contributionHeadroom(input: input, rulePack: rulePack)
        let probability = Double(successCount) / Double(request.pathCount)
        let medianRetirement = points[retirementIndex].p50
        let sustainableSpending = medianRetirement * (input.withdrawalRate ?? 0.04)
        let warnings = warningMessages(input: input, rulePack: rulePack)

        return RetirementProjection(
            id: UUID().uuidString,
            portfolioId: portfolioId.uuidString,
            ruleVersion: rulePack.version,
            currency: input.currency,
            summary: .init(
                readinessProbability: probability,
                sustainableAnnualSpending: sustainableSpending,
                projectedAnnualRetirementIncome: sustainableSpending + pensionIncome(input.publicPension, age: input.retirementAge) + input.otherAnnualRetirementIncome,
                annualContributionHeadroom: headroom,
                shortfallAge: shortfallAges.isEmpty ? nil : Int(shortfallAges.map(Double.init).reduce(0, +) / Double(shortfallAges.count)),
                medianValueAtRetirement: medianRetirement,
                medianValueAtLongevityAge: points.last?.p50 ?? 0
            ),
            points: points,
            assumptions: [
                "Returns are sampled annually from a normal distribution.",
                "All amounts are modeled in real user-entered currency without foreign-exchange forecasting.",
                "Public pension income is manual and begins at the entered age.",
            ],
            warnings: warnings,
            generatedAt: formatISODateTime(Date()) ?? ""
        )
    }

    private func validate(input: RetirementPlanInput, request: RetirementProjectionRequest) throws {
        guard input.currentAge >= 18, input.currentAge < 100 else {
            throw Abort(.badRequest, reason: "currentAge must be between 18 and 99.")
        }
        guard input.retirementAge > input.currentAge, input.retirementAge <= 100 else {
            throw Abort(.badRequest, reason: "retirementAge must be after currentAge and at most 100.")
        }
        guard input.longevityAge > input.retirementAge, input.longevityAge <= 120 else {
            throw Abort(.badRequest, reason: "longevityAge must be after retirementAge and at most 120.")
        }
        guard (100 ... 50000).contains(request.pathCount) else {
            throw Abort(.badRequest, reason: "pathCount must be between 100 and 50000.")
        }
        guard input.annualVolatility >= 0, input.annualVolatility <= 1 else {
            throw Abort(.badRequest, reason: "annualVolatility must be between 0 and 1.")
        }
    }

    private func annualContribution(input: RetirementPlanInput, salary: Double) -> Double {
        input.accounts.reduce(0) { total, account in
            var value = max(0, account.employeeAnnualContribution)
            if let match = account.employerMatch {
                let eligible = salary * max(0, match.upToSalaryPercent)
                let matched = min(account.employeeAnnualContribution, eligible) * max(0, match.matchRate)
                value += min(matched, match.annualCap ?? matched)
            }
            return total + value
        }
    }

    private func withdrawal(input: RetirementPlanInput, balance: Double, spending: Double) -> Double {
        switch input.withdrawalStrategy {
        case .fixedRealSpending:
            spending
        case .percentageOfPortfolio:
            balance * (input.withdrawalRate ?? 0.04)
        case .guardrails:
            min(spending * 1.20, max(spending * 0.80, balance * (input.withdrawalRate ?? 0.04)))
        }
    }

    private func pensionIncome(_ pension: RetirementPensionIncome?, age: Int) -> Double {
        guard let pension, age >= pension.startAge else { return 0 }
        return pension.annualAmount * pow(1 + pension.annualIndexationRate, Double(age - pension.startAge))
    }

    private func contributionHeadroom(input: RetirementPlanInput, rulePack: RetirementRulePack) -> Double {
        let rulesByWrapper = Dictionary(uniqueKeysWithValues: rulePack.wrappers.map { ($0.wrapper, $0) })
        return input.accounts.reduce(0) { total, account in
            guard let maximum = rulesByWrapper[account.wrapper]?.maximumEmployeeAnnualContribution else { return total }
            return total + max(0, maximum - account.employeeAnnualContribution)
        }
    }

    private func warningMessages(input: RetirementPlanInput, rulePack: RetirementRulePack) -> [String] {
        var warnings = [String]()
        let supported = Set(rulePack.wrappers.map(\.wrapper))
        if input.accounts.contains(where: { supported.contains($0.wrapper) == false && $0.wrapper != .taxable }) {
            warnings.append("One or more wrappers are not covered by this jurisdiction rule pack.")
        }
        if input.publicPension == nil {
            warnings.append("No public pension income was entered.")
        }
        if input.expectedAnnualReturn > 0.10 {
            warnings.append("The expected annual return is unusually high.")
        }
        return warnings
    }

    private func percentile(_ sorted: [Double], _ probability: Double) -> Double {
        guard sorted.isEmpty == false else { return 0 }
        let index = Int((Double(sorted.count - 1) * probability).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private func normal(mean: Double, standardDeviation: Double, random: inout SplitMix64) -> Double {
        guard standardDeviation > 0 else { return mean }
        let u1 = max(random.unitInterval(), Double.leastNonzeroMagnitude)
        let u2 = random.unitInterval()
        let standard = sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        return mean + standardDeviation * standard
    }
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func unitInterval() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
