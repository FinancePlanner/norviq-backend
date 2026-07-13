import Foundation
import StockPlanShared

struct FinancingBudgetContext: Sendable {
    let netMonthlyIncome: Double?
    let baselineSpending: Double
    let plannedSavings: Double
    let existingFinancingPayments: Double
}

enum FinancingCalculationError: Error {
    case invalidOffer
    case invalidDate
    case unsupportedCurrency
}

struct FinancingCalculator: Sendable {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    func simulate(
        request: FinancingSimulationRequest,
        assumptions: FinancingAffordabilityAssumptions,
        budget: FinancingBudgetContext
    ) throws -> FinancingSimulationResponse {
        guard request.offers.count == 1 || request.offers.count <= 3,
              request.currency.uppercased() == request.market.defaultCurrency
        else {
            throw FinancingCalculationError.invalidOffer
        }

        let results = try request.offers.map { offer in
            try simulate(
                offer: offer,
                market: request.market,
                purchaseType: request.purchaseType,
                currency: request.currency.uppercased(),
                assumptions: assumptions,
                budget: budget
            )
        }
        return .init(currency: request.currency.uppercased(), results: results, generatedAt: Self.timestamp(Date()) ?? "")
    }

    func projections(
        planId: String?,
        offer: FinancingOfferTerms,
        currency: String,
        matched: [Int: String] = [:]
    ) throws -> [FinancingProjectionResponse] {
        guard (1 ... 480).contains(offer.termMonths),
              offer.purchaseAmount > 0,
              offer.downPayment >= 0,
              offer.downPayment <= offer.purchaseAmount,
              offer.balloonPayment >= 0,
              let firstDate = Self.dayFormatter.date(from: offer.firstPaymentDate)
        else {
            throw FinancingCalculationError.invalidOffer
        }

        let payment = try monthlyPayment(for: offer)
        let today = calendar.startOfDay(for: Date())
        return try (1 ... offer.termMonths).map { installment in
            guard let dueDate = calendar.date(byAdding: .month, value: installment - 1, to: firstDate) else {
                throw FinancingCalculationError.invalidDate
            }
            let additional = additionalCost(for: installment, offer: offer)
            let balloon = installment == offer.termMonths ? offer.balloonPayment : 0
            let status: FinancingInstallmentStatus = if matched[installment] != nil {
                .matched
            } else if calendar.isDate(dueDate, inSameDayAs: today) {
                .due
            } else if dueDate < today {
                .overdue
            } else {
                .projected
            }
            return .init(
                planId: planId,
                offerId: offer.id,
                installmentNumber: installment,
                dueDate: Self.dayFormatter.string(from: dueDate),
                paymentAmount: Self.money(payment + balloon),
                additionalCostAmount: Self.money(additional),
                totalAmount: Self.money(payment + balloon + additional),
                currency: currency,
                status: status,
                matchedExpenseId: matched[installment]
            )
        }
    }

    private func simulate(
        offer: FinancingOfferTerms,
        market: FinancingMarket,
        purchaseType: FinancingPurchaseType,
        currency: String,
        assumptions: FinancingAffordabilityAssumptions,
        budget: FinancingBudgetContext
    ) throws -> FinancingOfferSimulationResponse {
        let projections = try projections(planId: nil, offer: offer, currency: currency)
        let payment = try monthlyPayment(for: offer)
        let loanPayments = payment * Double(offer.termMonths) + offer.balloonPayment
        let additional = projections.reduce(0) { $0 + $1.additionalCostAmount }
        let totalOut = offer.downPayment + offer.upfrontFees + loanPayments + additional
        let principal = financedPrincipal(for: offer)
        let creditCost = max(0, loanPayments + offer.upfrontFees - principal)
        let candidateMonthly = projections.map(\.totalAmount).max() ?? payment
        let affordability = FinancingPolicyRegistry.assess(
            market: market,
            purchaseType: purchaseType,
            candidateMonthlyPayment: candidateMonthly,
            assumptions: assumptions,
            budget: budget
        )
        var warnings: [String] = []
        if offer.rateType != .fixed {
            warnings.append("The projection holds the quoted payment constant. Variable-rate payments can change.")
        }
        if offer.effectiveAnnualRate != nil, offer.nominalAnnualRate == nil, offer.quotedMonthlyPayment != nil {
            warnings.append("The disclosed effective annual rate is shown for comparison; the provider's quoted payment drives this schedule.")
        }
        return .init(
            offer: offer,
            monthlyPayment: Self.money(payment),
            totalLoanPayments: Self.money(loanPayments),
            totalOutOfPocket: Self.money(totalOut),
            totalCreditCost: Self.money(creditCost),
            projections: projections,
            affordability: affordability,
            warnings: warnings
        )
    }

    private func financedPrincipal(for offer: FinancingOfferTerms) -> Double {
        offer.financedAmount ?? max(0, offer.purchaseAmount - offer.downPayment + offer.financedFees)
    }

    private func monthlyPayment(for offer: FinancingOfferTerms) throws -> Double {
        if let quote = offer.quotedMonthlyPayment, quote > 0 {
            return quote
        }
        guard let annualRate = offer.nominalAnnualRate, annualRate >= 0 else {
            throw FinancingCalculationError.invalidOffer
        }
        let principal = financedPrincipal(for: offer)
        let months = Double(offer.termMonths)
        let monthlyRate = annualRate / 100 / 12
        if monthlyRate == 0 {
            return max(0, principal - offer.balloonPayment) / months
        }
        let discount = pow(1 + monthlyRate, -months)
        return max(0, principal - offer.balloonPayment * discount) * monthlyRate / (1 - discount)
    }

    private func additionalCost(for installment: Int, offer: FinancingOfferTerms) -> Double {
        offer.additionalCosts.reduce(0) { total, cost in
            guard installment >= cost.startMonth,
                  installment <= (cost.endMonth ?? offer.termMonths)
            else { return total }
            switch cost.cadence {
            case .oneTime: return total + (installment == cost.startMonth ? cost.amount : 0)
            case .monthly: return total + cost.amount
            case .annual: return total + ((installment - cost.startMonth).isMultiple(of: 12) ? cost.amount : 0)
            }
        }
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func timestamp(_ date: Date?) -> String? {
        guard let date else { return nil }
        return ISO8601DateFormatter().string(from: date)
    }

    static func money(_ value: Double) -> Double {
        (value * 100).rounded(.toNearestOrEven) / 100
    }
}
