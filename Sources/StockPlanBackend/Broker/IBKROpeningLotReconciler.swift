import Foundation

enum IBKROpeningLotReconciliationError: Error, Equatable {
    case consumedQuantityExceedsRequired(consumed: Double, required: Double)
}

struct IBKROpeningLotReconciler: Sendable {
    func requiredQuantity(position: Double, bought: Double, sold: Double) -> Double {
        max(0, max(0, position) + max(0, sold) - max(0, bought))
    }

    func remainingQuantity(required: Double, consumed: Double) throws -> Double {
        let normalizedRequired = max(0, required)
        let normalizedConsumed = max(0, consumed)
        guard normalizedRequired + 0.000_000_1 >= normalizedConsumed else {
            throw IBKROpeningLotReconciliationError.consumedQuantityExceedsRequired(
                consumed: normalizedConsumed,
                required: normalizedRequired
            )
        }
        return max(0, normalizedRequired - normalizedConsumed)
    }
}
