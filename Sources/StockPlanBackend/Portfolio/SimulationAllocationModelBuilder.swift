import Foundation
import StockPlanShared

enum SimulationModelError: Error, Equatable {
    /// Legs claim more than 100% of the portfolio.
    case weightsExceedTotal(Int)
    case noLegs
    case duplicateSymbol(String)
    case invalidSymbol(String)
    case invalidTargetCapital
    case invalidWeight(String)
}

/// Turns a simulation's legs into an `AllocationModel` value that is handed straight
/// to `RebalancingEngine` and never persisted. The engine has no stored properties
/// and no Fluent coupling, so a synthetic model is a first-class input to it.
///
/// Three engine constraints shape what this emits:
///
/// 1. `validate` requires buckets to total exactly 10000 bp, so any weight the legs
///    do not claim becomes a cash bucket.
/// 2. `validate` also requires every bucket and leaf to be strictly positive, so when
///    legs total exactly 10000 the cash bucket must be omitted rather than set to zero.
/// 3. A bucket's target must equal the sum of its leaves, which one leaf per bucket
///    satisfies trivially — and it makes the engine's before/after rows read as a flat
///    list of positions, which is what a simulation UI wants.
struct SimulationAllocationModelBuilder: Sendable {
    static let cashLeafIdentifier = "cash"

    func makeModel(for simulation: PortfolioSimulation) throws -> AllocationModel {
        guard !simulation.legs.isEmpty else { throw SimulationModelError.noLegs }

        var seen = Set<String>()
        var buckets = [AllocationTargetBucket]()
        var claimed = 0

        for (offset, leg) in simulation.legs.sorted(by: sortLegs).enumerated() {
            let symbol = Self.normalize(leg.symbol)
            guard Self.validSymbol(symbol) else { throw SimulationModelError.invalidSymbol(leg.symbol) }
            guard leg.targetBasisPoints > 0, leg.targetBasisPoints <= 10000 else {
                throw SimulationModelError.invalidWeight(symbol)
            }
            guard seen.insert(symbol).inserted else { throw SimulationModelError.duplicateSymbol(symbol) }

            claimed += leg.targetBasisPoints
            let label = leg.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (label?.isEmpty == false ? label! : symbol)
            buckets.append(
                AllocationTargetBucket(
                    id: symbol,
                    name: name,
                    targetBasisPoints: leg.targetBasisPoints,
                    sortOrder: offset,
                    leaves: [
                        AllocationTargetLeaf(
                            id: symbol,
                            kind: .security,
                            symbol: symbol,
                            name: name,
                            targetBasisPoints: leg.targetBasisPoints,
                            sortOrder: offset
                        ),
                    ]
                )
            )
        }

        guard claimed <= 10000 else { throw SimulationModelError.weightsExceedTotal(claimed) }

        // Only when the legs leave room. A zero-basis-point bucket fails validation.
        let cash = 10000 - claimed
        if cash > 0 {
            buckets.append(
                AllocationTargetBucket(
                    id: Self.cashLeafIdentifier,
                    name: "Cash",
                    targetBasisPoints: cash,
                    sortOrder: buckets.count,
                    leaves: [
                        AllocationTargetLeaf(
                            id: Self.cashLeafIdentifier,
                            kind: .cash,
                            symbol: nil,
                            name: "Cash",
                            targetBasisPoints: cash,
                            sortOrder: buckets.count
                        ),
                    ]
                )
            )
        }

        return AllocationModel(
            id: simulation.id,
            portfolioId: simulation.sourcePortfolioId ?? simulation.id,
            name: simulation.name,
            groupingMode: .holding,
            isActive: false,
            revision: simulation.revision,
            baseCurrency: simulation.baseCurrency,
            // Drift severity is a rebalancing concept. A simulation describes a target
            // state, so nothing should ever be reported as breached.
            defaultTargetThresholdBasisPoints: 10000,
            totalThresholdBasisPoints: 10000,
            fractionalSharesEnabled: simulation.fractionalSharesEnabled,
            // The engine never reads `fractionalSharesEnabled`; only `quantityIncrement`
            // reaches `roundedQuantity`. `RebalancingService` encodes the toggle the same
            // way, and skipping this mapping makes the toggle a silent no-op.
            quantityIncrement: simulation.fractionalSharesEnabled ? simulation.quantityIncrement : 1,
            minimumTradeAmount: simulation.minimumTradeAmount,
            flatFee: simulation.flatFee,
            variableFeeBasisPoints: simulation.variableFeeBasisPoints,
            buckets: buckets,
            createdAt: simulation.createdAt,
            updatedAt: simulation.updatedAt
        )
    }

    func makeRequest(for model: AllocationModel, cashFlow: Double) -> RebalancingSimulationRequest {
        RebalancingSimulationRequest(modelId: model.id, modelRevision: model.revision, cashFlow: cashFlow)
    }

    private func sortLegs(_ lhs: PortfolioSimulationLeg, _ rhs: PortfolioSimulationLeg) -> Bool {
        lhs.sortOrder == rhs.sortOrder ? lhs.symbol < rhs.symbol : lhs.sortOrder < rhs.sortOrder
    }

    static func normalize(_ symbol: String?) -> String {
        symbol?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
    }

    static func validSymbol(_ symbol: String) -> Bool {
        guard !symbol.isEmpty, symbol.count <= 24, let first = symbol.unicodeScalars.first else { return false }
        let allowedFirst = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789^")
        let allowed = allowedFirst.union(CharacterSet(charactersIn: ".-_:"))
        return allowedFirst.contains(first) && symbol.unicodeScalars.allSatisfy(allowed.contains)
    }
}
