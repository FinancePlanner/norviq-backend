import Foundation
import StockPlanShared

enum RebalancingEngineError: Error, Equatable {
    case invalidModel(String)
    case invalidHolding(String)
    case invalidCashFlow
    case staleModel
    case unknownOverride(String)
    case oversell(String)
    case insufficientCash
}

struct RebalancingHolding: Sendable, Equatable {
    let symbol: String
    let name: String
    let quantity: Double
    let price: Double
    let averageCost: Double

    var value: Double {
        quantity * price
    }
}

struct RebalancingValuationSnapshot: Sendable, Equatable {
    let holdings: [RebalancingHolding]
    let cash: Double
    let baseCurrency: String
    let priceQuality: RebalancingPriceQuality
    let pricedAt: String?
    let warnings: [RebalancingValuationWarning]
}

struct RebalancingEngine: Sendable {
    func validate(_ model: AllocationModel) throws {
        guard !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RebalancingEngineError.invalidModel("Model name is required.")
        }
        guard !model.buckets.isEmpty else {
            throw RebalancingEngineError.invalidModel("At least one allocation bucket is required.")
        }
        guard model.buckets.reduce(0, { $0 + $1.targetBasisPoints }) == 10000 else {
            throw RebalancingEngineError.invalidModel("Bucket targets must total exactly 100%.")
        }
        guard (1 ... 10000).contains(model.defaultTargetThresholdBasisPoints),
              (1 ... 10000).contains(model.totalThresholdBasisPoints),
              model.quantityIncrement.isFinite,
              model.quantityIncrement > 0,
              model.minimumTradeAmount.isFinite,
              model.minimumTradeAmount >= 0,
              model.flatFee.isFinite,
              model.flatFee >= 0,
              (0 ... 10000).contains(model.variableFeeBasisPoints)
        else {
            throw RebalancingEngineError.invalidModel("Thresholds and trade constraints must be positive.")
        }

        var symbols = Set<String>()
        var cashCount = 0
        for bucket in model.buckets {
            guard !bucket.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RebalancingEngineError.invalidModel("Bucket names are required.")
            }
            guard bucket.targetBasisPoints > 0,
                  !bucket.leaves.isEmpty,
                  bucket.leaves.reduce(0, { $0 + $1.targetBasisPoints }) == bucket.targetBasisPoints
            else {
                throw RebalancingEngineError.invalidModel("Each bucket must equal the sum of its holding targets.")
            }
            if let threshold = bucket.alertThresholdBasisPoints,
               !(1 ... 10000).contains(threshold)
            {
                throw RebalancingEngineError.invalidModel("Bucket alert thresholds must be between 0.01% and 100%.")
            }
            for leaf in bucket.leaves {
                guard leaf.targetBasisPoints > 0,
                      !leaf.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw RebalancingEngineError.invalidModel("Holding targets and names are required.")
                }
                if let threshold = leaf.alertThresholdBasisPoints,
                   !(1 ... 10000).contains(threshold)
                {
                    throw RebalancingEngineError.invalidModel("Holding alert thresholds must be between 0.01% and 100%.")
                }
                switch leaf.kind {
                case .cash:
                    cashCount += 1
                    guard leaf.symbol == nil else {
                        throw RebalancingEngineError.invalidModel("Cash targets cannot have a symbol.")
                    }
                case .security:
                    let symbol = normalize(leaf.symbol)
                    guard validSymbol(symbol) else {
                        throw RebalancingEngineError.invalidModel("Security targets require a valid ticker of at most 24 characters.")
                    }
                    guard symbols.insert(symbol).inserted else {
                        throw RebalancingEngineError.invalidModel("Each security may appear only once.")
                    }
                }
            }
        }
        guard cashCount <= 1 else {
            throw RebalancingEngineError.invalidModel("A model can contain only one cash target.")
        }
    }

    func overview(
        portfolioId: String,
        model: AllocationModel?,
        snapshot: RebalancingValuationSnapshot,
        openAlertCount: Int = 0
    ) throws -> RebalancingOverview {
        guard let model else {
            return RebalancingOverview(
                portfolioId: portfolioId,
                model: nil,
                baseCurrency: snapshot.baseCurrency,
                totalValue: roundedMoney(snapshot.holdings.reduce(snapshot.cash) { $0 + $1.value }),
                totalDriftBasisPoints: 0,
                severity: .unavailable,
                priceQuality: snapshot.priceQuality,
                pricedAt: snapshot.pricedAt,
                openAlertCount: openAlertCount,
                rows: [],
                warnings: snapshot.warnings
            )
        }
        try validate(model)
        let values = try holdingValues(snapshot.holdings)
        let total = values.values.reduce(max(0, snapshot.cash), +)
        let result = allocationRows(model: model, values: values, cash: max(0, snapshot.cash), total: total)
        let severity: RebalancingDriftSeverity = if snapshot.priceQuality == .incomplete {
            .unavailable
        } else {
            severity(drift: result.totalDrift, threshold: model.totalThresholdBasisPoints)
        }
        return RebalancingOverview(
            portfolioId: portfolioId,
            model: model,
            baseCurrency: snapshot.baseCurrency,
            totalValue: roundedMoney(total),
            totalDriftBasisPoints: result.totalDrift,
            severity: severity,
            priceQuality: snapshot.priceQuality,
            pricedAt: snapshot.pricedAt,
            openAlertCount: openAlertCount,
            rows: result.rows,
            warnings: snapshot.warnings
        )
    }

    func simulate(
        portfolioId: String,
        model: AllocationModel,
        request: RebalancingSimulationRequest,
        snapshot: RebalancingValuationSnapshot
    ) throws -> RebalancingSimulation {
        try validate(model)
        guard request.modelRevision == model.revision, request.modelId == model.id else {
            throw RebalancingEngineError.staleModel
        }
        guard request.cashFlow.isFinite else { throw RebalancingEngineError.invalidCashFlow }

        let holdingsBySymbol = try Dictionary(
            uniqueKeysWithValues: snapshot.holdings.map { holding -> (String, RebalancingHolding) in
                guard holding.quantity >= 0, holding.price > 0, holding.price.isFinite else {
                    throw RebalancingEngineError.invalidHolding(holding.symbol)
                }
                return (normalize(holding.symbol), holding)
            }
        )
        let beforeValues = holdingsBySymbol.mapValues(\.value)
        let startingCash = snapshot.cash + request.cashFlow
        guard startingCash >= 0 else { throw RebalancingEngineError.insufficientCash }
        let totalBefore = beforeValues.values.reduce(startingCash, +)
        let beforeRows = allocationRows(model: model, values: beforeValues, cash: startingCash, total: totalBefore)

        let targetSecurityLeaves = model.buckets.flatMap(\.leaves).filter { $0.kind == .security }
        let targetSymbols = Set(targetSecurityLeaves.compactMap { normalize($0.symbol) })
        let heldSymbols = Set(holdingsBySymbol.keys)
        let overrides = try overrideMap(request.overrides, allowedSymbols: targetSymbols.union(heldSymbols))
        var candidates = [TradeCandidate]()

        for leaf in targetSecurityLeaves {
            let symbol = normalize(leaf.symbol)
            guard let holding = holdingsBySymbol[symbol] else {
                throw RebalancingEngineError.invalidHolding("No live price is available for \(symbol).")
            }
            let desired = totalBefore * Double(leaf.targetBasisPoints) / 10000
            let rawAmount = overrides[symbol] ?? (desired - holding.value)
            guard rawAmount.isFinite else { throw RebalancingEngineError.invalidHolding(symbol) }
            if rawAmount < 0, abs(rawAmount) > holding.value + 0.005 {
                throw RebalancingEngineError.oversell(symbol)
            }
            guard abs(rawAmount) >= model.minimumTradeAmount else { continue }
            let quantity = roundedQuantity(abs(rawAmount) / holding.price, increment: model.quantityIncrement)
            let maxQuantity = rawAmount < 0 ? min(quantity, holding.quantity) : quantity
            let notional = roundedMoney(maxQuantity * holding.price)
            guard notional >= model.minimumTradeAmount, maxQuantity > 0 else { continue }
            candidates.append(
                TradeCandidate(
                    holding: holding,
                    side: rawAmount >= 0 ? .buy : .sell,
                    quantity: maxQuantity,
                    notional: notional
                )
            )
        }

        for symbol in heldSymbols.subtracting(targetSymbols).sorted() {
            guard let holding = holdingsBySymbol[symbol], holding.quantity > 0 else { continue }
            let rawAmount = overrides[symbol] ?? -holding.value
            guard rawAmount.isFinite else { throw RebalancingEngineError.invalidHolding(symbol) }
            if rawAmount < 0, abs(rawAmount) > holding.value + 0.005 {
                throw RebalancingEngineError.oversell(symbol)
            }
            guard abs(rawAmount) >= model.minimumTradeAmount else { continue }
            let quantity = roundedQuantity(abs(rawAmount) / holding.price, increment: model.quantityIncrement)
            let maxQuantity = rawAmount < 0 ? min(quantity, holding.quantity) : quantity
            let notional = roundedMoney(maxQuantity * holding.price)
            guard notional >= model.minimumTradeAmount, maxQuantity > 0 else { continue }
            candidates.append(
                TradeCandidate(
                    holding: holding,
                    side: rawAmount >= 0 ? .buy : .sell,
                    quantity: maxQuantity,
                    notional: notional
                )
            )
        }

        candidates = try fundBuys(candidates, startingCash: startingCash, model: model)
        let trades = candidates.map { makeTrade($0, model: model, currency: snapshot.baseCurrency) }
            .sorted { lhs, rhs in
                if lhs.side != rhs.side {
                    return lhs.side == .sell
                }
                return lhs.symbol < rhs.symbol
            }

        var afterValues = beforeValues
        var cashAfter = startingCash
        for trade in trades {
            let signed = trade.side == .buy ? trade.notional : -trade.notional
            afterValues[trade.symbol, default: 0] += signed
            cashAfter += trade.side == .sell ? trade.notional : -trade.notional
            cashAfter -= trade.estimatedFee
        }
        guard cashAfter >= -0.01 else { throw RebalancingEngineError.insufficientCash }
        cashAfter = max(0, cashAfter)
        let totalAfter = afterValues.values.reduce(cashAfter, +)
        let afterRows = allocationRows(model: model, values: afterValues, cash: cashAfter, total: totalAfter)

        return RebalancingSimulation(
            portfolioId: portfolioId,
            modelId: model.id,
            modelRevision: model.revision,
            baseCurrency: snapshot.baseCurrency,
            totalValueBefore: roundedMoney(totalBefore),
            totalValueAfter: roundedMoney(totalAfter),
            driftBeforeBasisPoints: beforeRows.totalDrift,
            driftAfterBasisPoints: afterRows.totalDrift,
            estimatedFees: roundedMoney(trades.reduce(0) { $0 + $1.estimatedFee }),
            estimatedRealizedGainLoss: roundedMoney(trades.compactMap(\.estimatedRealizedGainLoss).reduce(0, +)),
            trades: trades,
            before: beforeRows.rows,
            after: afterRows.rows,
            warnings: snapshot.warnings,
            pricedAt: snapshot.pricedAt
        )
    }

    private func holdingValues(_ holdings: [RebalancingHolding]) throws -> [String: Double] {
        var result: [String: Double] = [:]
        for holding in holdings {
            guard holding.quantity >= 0, holding.price > 0, holding.price.isFinite else {
                throw RebalancingEngineError.invalidHolding(holding.symbol)
            }
            result[normalize(holding.symbol), default: 0] += holding.value
        }
        return result
    }

    private func allocationRows(
        model: AllocationModel,
        values: [String: Double],
        cash: Double,
        total: Double
    ) -> (rows: [RebalancingAllocationRow], totalDrift: Int) {
        var assigned = Set<String>()
        var leafAbsoluteDrift = 0
        var bucketRows = [RebalancingAllocationRow]()

        for bucket in model.buckets.sorted(by: sortBuckets) {
            var childRows = [RebalancingAllocationRow]()
            for leaf in bucket.leaves.sorted(by: sortLeaves) {
                let symbol = leaf.kind == .security ? normalize(leaf.symbol) : nil
                if let symbol {
                    assigned.insert(symbol)
                }
                let currentValue = leaf.kind == .cash ? cash : values[symbol ?? "", default: 0]
                let currentBps = basisPoints(currentValue, total: total)
                let drift = currentBps - leaf.targetBasisPoints
                leafAbsoluteDrift += abs(drift)
                let threshold = leaf.alertThresholdBasisPoints ?? model.defaultTargetThresholdBasisPoints
                childRows.append(
                    RebalancingAllocationRow(
                        id: leaf.id,
                        label: leaf.name,
                        symbol: symbol,
                        targetBasisPoints: leaf.targetBasisPoints,
                        currentBasisPoints: currentBps,
                        driftBasisPoints: drift,
                        currentValue: roundedMoney(currentValue),
                        targetValue: roundedMoney(total * Double(leaf.targetBasisPoints) / 10000),
                        driftValue: roundedMoney(currentValue - total * Double(leaf.targetBasisPoints) / 10000),
                        severity: severity(drift: abs(drift), threshold: threshold)
                    )
                )
            }
            let bucketCurrent = childRows.reduce(0) { $0 + $1.currentValue }
            let bucketCurrentBps = basisPoints(bucketCurrent, total: total)
            let bucketDrift = bucketCurrentBps - bucket.targetBasisPoints
            bucketRows.append(
                RebalancingAllocationRow(
                    id: bucket.id,
                    label: bucket.name,
                    targetBasisPoints: bucket.targetBasisPoints,
                    currentBasisPoints: bucketCurrentBps,
                    driftBasisPoints: bucketDrift,
                    currentValue: roundedMoney(bucketCurrent),
                    targetValue: roundedMoney(total * Double(bucket.targetBasisPoints) / 10000),
                    driftValue: roundedMoney(bucketCurrent - total * Double(bucket.targetBasisPoints) / 10000),
                    severity: severity(
                        drift: abs(bucketDrift),
                        threshold: bucket.alertThresholdBasisPoints ?? model.defaultTargetThresholdBasisPoints
                    ),
                    children: childRows
                )
            )
        }

        let unassigned = values.filter { !assigned.contains($0.key) && $0.value > 0 }
        if !unassigned.isEmpty {
            let children = unassigned.sorted(by: { $0.key < $1.key }).map { symbol, value in
                let drift = basisPoints(value, total: total)
                leafAbsoluteDrift += drift
                return RebalancingAllocationRow(
                    id: "unassigned:\(symbol)",
                    label: symbol,
                    symbol: symbol,
                    targetBasisPoints: 0,
                    currentBasisPoints: drift,
                    driftBasisPoints: drift,
                    currentValue: roundedMoney(value),
                    targetValue: 0,
                    driftValue: roundedMoney(value),
                    severity: severity(drift: drift, threshold: model.defaultTargetThresholdBasisPoints)
                )
            }
            let value = children.reduce(0) { $0 + $1.currentValue }
            let drift = basisPoints(value, total: total)
            bucketRows.append(
                RebalancingAllocationRow(
                    id: "unassigned",
                    label: "Unassigned",
                    targetBasisPoints: 0,
                    currentBasisPoints: drift,
                    driftBasisPoints: drift,
                    currentValue: roundedMoney(value),
                    targetValue: 0,
                    driftValue: roundedMoney(value),
                    severity: severity(drift: drift, threshold: model.defaultTargetThresholdBasisPoints),
                    children: children
                )
            )
        }
        return (bucketRows, leafAbsoluteDrift / 2)
    }

    private func overrideMap(
        _ overrides: [RebalanceTradeOverride],
        allowedSymbols: Set<String>
    ) throws -> [String: Double] {
        var result: [String: Double] = [:]
        for override in overrides {
            let symbol = normalize(override.symbol)
            guard allowedSymbols.contains(symbol), result[symbol] == nil else {
                throw RebalancingEngineError.unknownOverride(symbol)
            }
            result[symbol] = override.amount
        }
        return result
    }

    private func fundBuys(
        _ candidates: [TradeCandidate],
        startingCash: Double,
        model: AllocationModel
    ) throws -> [TradeCandidate] {
        let sells = candidates.filter { $0.side == .sell }
        let buys = candidates.filter { $0.side == .buy }
        let sellProceeds = sells.reduce(0) { $0 + $1.notional - fee(for: $1.notional, model: model) }
        let available = startingCash + sellProceeds
        let buyCost = buys.reduce(0) { $0 + $1.notional + fee(for: $1.notional, model: model) }
        guard buyCost > available + 0.005 else { return candidates }
        guard available > 0, !buys.isEmpty else { throw RebalancingEngineError.insufficientCash }

        let flatFees = Double(buys.count) * model.flatFee
        let variableRate = Double(model.variableFeeBasisPoints) / 10000
        let scalable = max(0, available - flatFees)
        let maxBuyNotional = scalable / (1 + variableRate)
        let originalBuyNotional = buys.reduce(0) { $0 + $1.notional }
        guard maxBuyNotional > 0, originalBuyNotional > 0 else {
            throw RebalancingEngineError.insufficientCash
        }
        let scale = min(1, maxBuyNotional / originalBuyNotional)
        let scaledBuys = buys.compactMap { candidate -> TradeCandidate? in
            let quantity = roundedQuantity(
                candidate.quantity * scale,
                increment: model.quantityIncrement
            )
            let notional = roundedMoney(quantity * candidate.holding.price)
            guard quantity > 0, notional >= model.minimumTradeAmount else { return nil }
            return TradeCandidate(
                holding: candidate.holding,
                side: .buy,
                quantity: quantity,
                notional: notional
            )
        }
        return sells + scaledBuys
    }

    private func makeTrade(
        _ candidate: TradeCandidate,
        model: AllocationModel,
        currency: String
    ) -> RebalanceTrade {
        let basis = candidate.side == .sell
            ? roundedMoney(candidate.quantity * candidate.holding.averageCost)
            : nil
        return RebalanceTrade(
            symbol: normalize(candidate.holding.symbol),
            side: candidate.side,
            quantity: candidate.quantity,
            price: roundedMoney(candidate.holding.price),
            notional: candidate.notional,
            estimatedFee: fee(for: candidate.notional, model: model),
            estimatedCostBasis: basis,
            estimatedRealizedGainLoss: basis.map { roundedMoney(candidate.notional - $0) },
            currency: currency
        )
    }

    private func fee(for notional: Double, model: AllocationModel) -> Double {
        roundedMoney(model.flatFee + notional * Double(model.variableFeeBasisPoints) / 10000)
    }

    private func severity(drift: Int, threshold: Int) -> RebalancingDriftSeverity {
        let absolute = abs(drift)
        if absolute >= threshold {
            return .breached
        }
        if absolute * 5 >= threshold * 4 {
            return .warning
        }
        return .balanced
    }

    private func basisPoints(_ value: Double, total: Double) -> Int {
        guard total > 0 else { return 0 }
        return Int((value / total * 10000).rounded())
    }

    private func roundedMoney(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private func roundedQuantity(_ value: Double, increment: Double) -> Double {
        guard increment > 0 else { return value }
        return (value / increment).rounded(.down) * increment
    }

    private func normalize(_ symbol: String?) -> String {
        symbol?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
    }

    private func validSymbol(_ symbol: String) -> Bool {
        guard !symbol.isEmpty, symbol.count <= 24, let first = symbol.unicodeScalars.first else { return false }
        let allowedFirst = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789^")
        let allowed = allowedFirst.union(CharacterSet(charactersIn: ".-_:"))
        return allowedFirst.contains(first) && symbol.unicodeScalars.allSatisfy(allowed.contains)
    }

    private func sortBuckets(_ lhs: AllocationTargetBucket, _ rhs: AllocationTargetBucket) -> Bool {
        lhs.sortOrder == rhs.sortOrder ? lhs.name < rhs.name : lhs.sortOrder < rhs.sortOrder
    }

    private func sortLeaves(_ lhs: AllocationTargetLeaf, _ rhs: AllocationTargetLeaf) -> Bool {
        lhs.sortOrder == rhs.sortOrder ? lhs.name < rhs.name : lhs.sortOrder < rhs.sortOrder
    }
}

private struct TradeCandidate {
    let holding: RebalancingHolding
    let side: RebalanceTradeSide
    let quantity: Double
    let notional: Double
}
