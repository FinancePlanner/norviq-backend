import Fluent
import Foundation
import StockPlanShared

/// Resolves monthly expense spending from the user's latest budget snapshot for scenario impact metrics.
enum ScenarioBudgetSpending {
    /// Returns user-share-adjusted planned expense spending for the latest budget month, or nil when unknown.
    static func monthlyExpenseSpending(userId: UUID, on database: any Database) async throws -> Double? {
        guard let snapshot = try await BudgetSnapshot.query(on: database)
            .filter(\.$user.$id == userId)
            .sort(\.$monthStart, .descending)
            .first(),
            let snapshotId = snapshot.id
        else {
            return nil
        }
        let items = try await BudgetPlanItem.query(on: database)
            .filter(\.$snapshot.$id == snapshotId)
            .all()
        let total = expenseTotal(
            items: items.map {
                (allocationKind: $0.allocationKind, plannedAmount: $0.plannedAmount, userSharePercent: $0.userSharePercent)
            }
        )
        guard total > 0, total.isFinite else { return nil }
        return total
    }

    /// Sum of non-investment plan lines, scaled by user share percent (same basis as financing affordability).
    static func expenseTotal(
        items: [(allocationKind: BudgetAllocationKind, plannedAmount: Double, userSharePercent: Double)]
    ) -> Double {
        items.reduce(0) { total, item in
            guard item.allocationKind != .investmentContribution else { return total }
            guard item.plannedAmount.isFinite, item.userSharePercent.isFinite else { return total }
            let share = max(0, min(item.userSharePercent, 100)) / 100
            return total + max(0, item.plannedAmount) * share
        }
    }
}
