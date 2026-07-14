import Foundation
import StockPlanShared

struct ScreenMetricObservation: Sendable, Equatable {
    let current: Double?
    let previous: Double?
}

struct WatchlistScreenEvaluator: Sendable {
    static let catalog: [ScreenMetricDescriptor] = [
        .init(id: "price", label: "Price", category: .quote, supportedPeriods: [.ttm], supportedComparisons: numeric, unit: "currency"),
        .init(id: "market_cap", label: "Market cap", category: .quote, supportedPeriods: [.ttm], supportedComparisons: numeric, unit: "currency"),
        .init(id: "pe_ratio", label: "P/E ratio", category: .valuation, supportedPeriods: [.ttm, .annual, .quarterly], supportedComparisons: numeric, unit: "ratio", favorableDirection: "lower"),
        .init(id: "price_to_sales", label: "Price to sales", category: .valuation, supportedPeriods: [.ttm, .annual, .quarterly], supportedComparisons: numeric, unit: "ratio", favorableDirection: "lower"),
        .init(id: "net_profit_margin", label: "Net profit margin", category: .profitability, supportedPeriods: [.ttm, .annual, .quarterly], supportedComparisons: trend, unit: "percent", favorableDirection: "higher"),
        .init(id: "revenue_growth", label: "Revenue growth", category: .growth, supportedPeriods: [.annual, .quarterly], supportedComparisons: trend, unit: "percent", favorableDirection: "higher"),
        .init(id: "eps_growth", label: "EPS growth", category: .growth, supportedPeriods: [.annual, .quarterly], supportedComparisons: trend, unit: "percent", favorableDirection: "higher"),
        .init(id: "debt_to_equity", label: "Debt to equity", category: .leverage, supportedPeriods: [.ttm, .annual, .quarterly], supportedComparisons: trend, unit: "ratio", favorableDirection: "lower"),
        .init(id: "current_ratio", label: "Current ratio", category: .liquidity, supportedPeriods: [.ttm, .annual, .quarterly], supportedComparisons: trend, unit: "ratio", favorableDirection: "higher"),
        .init(id: "free_cash_flow", label: "Free cash flow per share", category: .cashFlow, supportedPeriods: [.ttm, .annual, .quarterly], supportedComparisons: trend, unit: "currency", favorableDirection: "higher"),
        .init(id: "dividend_yield", label: "Dividend yield", category: .dividend, supportedPeriods: [.ttm, .annual, .quarterly], supportedComparisons: trend, unit: "percent", favorableDirection: "higher"),
    ]

    private static let numeric: [ScreenComparison] = [.greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual, .equal]
    private static let trend: [ScreenComparison] = numeric + [.improving, .deteriorating]

    func evaluate(
        condition: WatchlistScreenCondition,
        observation: ScreenMetricObservation,
        descriptor: ScreenMetricDescriptor
    ) -> ScreenConditionResult {
        guard let current = observation.current else {
            return .init(conditionId: condition.id, matched: false, explanation: "No data is available for this metric and period.")
        }
        let matched: Bool
        switch condition.comparison {
        case .greaterThan: matched = current > (condition.value ?? .infinity)
        case .greaterThanOrEqual: matched = current >= (condition.value ?? .infinity)
        case .lessThan: matched = current < (condition.value ?? -.infinity)
        case .lessThanOrEqual: matched = current <= (condition.value ?? -.infinity)
        case .equal: matched = abs(current - (condition.value ?? .infinity)) < 0.000_001
        case .improving, .deteriorating:
            guard condition.period != .ttm, let previous = observation.previous else {
                return .init(
                    conditionId: condition.id,
                    matched: false,
                    value: current,
                    explanation: "A previous completed period is required for trend comparisons."
                )
            }
            let higherIsBetter = descriptor.favorableDirection == "higher"
            let improvement = higherIsBetter ? current > previous : current < previous
            matched = condition.comparison == .improving ? improvement : !improvement && current != previous
        }
        return .init(
            conditionId: condition.id,
            matched: matched,
            value: current,
            previousValue: observation.previous,
            explanation: matched ? "Condition matched." : "Condition did not match."
        )
    }

    func combines(_ values: [Bool], using operatorValue: ScreenLogicalOperator) -> Bool {
        guard !values.isEmpty else { return false }
        return operatorValue == .all ? values.allSatisfy(\.self) : values.contains(true)
    }
}

struct RebalanceValuation: Sendable, Equatable {
    let kind: RebalanceAssetKind
    let symbol: String?
    let value: Double
    let price: Double?
}

struct RebalancingEngine: Sendable {
    func preview(
        policy: RebalancingPolicy,
        valuations: [RebalanceValuation],
        currency: String,
        now: Date = Date()
    ) throws -> RebalancePreview {
        try policy.validate()
        let total = valuations.reduce(0) { $0 + $1.value }
        guard total > 0 else { throw WealthAutomationValidationError.invalidAmount }
        let values = valuations.reduce(into: [String: RebalanceValuation]()) { result, valuation in
            let valuationKey = key(kind: valuation.kind, symbol: valuation.symbol)
            if let existing = result[valuationKey] {
                result[valuationKey] = RebalanceValuation(
                    kind: valuation.kind,
                    symbol: valuation.symbol,
                    value: existing.value + valuation.value,
                    price: existing.price ?? valuation.price
                )
            } else {
                result[valuationKey] = valuation
            }
        }
        var maximumDrift = 0.0
        let targetKeys = Set(policy.targets.map { key(kind: $0.kind, symbol: $0.symbol) })
        var trades = policy.targets.map { target in
            let targetKey = key(kind: target.kind, symbol: target.symbol)
            let valuation = values[targetKey]
            let currentValue = valuation?.value ?? 0
            let currentWeight = currentValue / total
            let delta = target.targetWeight * total - currentValue
            maximumDrift = max(maximumDrift, abs(currentWeight - target.targetWeight))
            let action: RebalanceAction = abs(delta) < 0.01 ? .hold : (delta > 0 ? .buy : .sell)
            return RebalanceTradeDraft(
                id: target.id,
                kind: target.kind,
                symbol: target.symbol,
                action: action,
                currentWeight: currentWeight,
                targetWeight: target.targetWeight,
                amount: abs(delta),
                approximateShares: valuation?.price.flatMap { $0 > 0 ? abs(delta) / $0 : nil }
            )
        }
        let liquidationTrades = values
            .filter { targetKeys.contains($0.key) == false && abs($0.value.value) >= 0.01 }
            .sorted { $0.key < $1.key }
            .map { valuationKey, valuation in
                let currentWeight = valuation.value / total
                maximumDrift = max(maximumDrift, abs(currentWeight))
                return RebalanceTradeDraft(
                    id: "liquidate:\(valuationKey)",
                    kind: valuation.kind,
                    symbol: valuation.symbol,
                    action: .sell,
                    currentWeight: currentWeight,
                    targetWeight: 0,
                    amount: abs(valuation.value),
                    approximateShares: valuation.price.flatMap { $0 > 0 ? abs(valuation.value) / $0 : nil }
                )
            }
        trades.append(contentsOf: liquidationTrades)
        var reasons: [RebalanceTriggerReason] = []
        if let threshold = policy.driftThreshold, maximumDrift > threshold {
            reasons.append(.drift)
        }
        if cadenceDue(policy: policy, now: now) {
            reasons.append(.cadence)
        }
        return .init(
            portfolioValue: total,
            currency: currency,
            maximumDrift: maximumDrift,
            triggerReasons: reasons,
            trades: trades
        )
    }

    private func cadenceDue(policy: RebalancingPolicy, now: Date) -> Bool {
        guard policy.cadence != .disabled else { return false }
        let rawReference = policy.lastConfirmedAt ?? policy.createdAt
        guard let rawReference, let reference = ISO8601DateFormatter().date(from: rawReference) else { return false }
        let months: Int
        switch policy.cadence {
        case .monthly: months = 1
        case .quarterly: months = 3
        case .semiannual: months = 6
        case .annual: months = 12
        case .disabled: return false
        }
        return Calendar(identifier: .gregorian).date(byAdding: .month, value: months, to: reference).map { now >= $0 } ?? false
    }

    private func key(kind: RebalanceAssetKind, symbol: String?) -> String {
        kind == .cash ? "cash" : "symbol:\(symbol?.uppercased() ?? "")"
    }
}
