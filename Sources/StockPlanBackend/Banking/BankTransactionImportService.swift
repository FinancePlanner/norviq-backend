import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Converts a reviewed bank transaction into an expense. Import is always
/// user-initiated (never automatic) to avoid double-counting budgets.
struct BankTransactionImportService: Sendable {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    func importTransaction(
        _ transaction: BankTransaction,
        request: BankTransactionImportRequest,
        userId: UUID,
        on req: Request
    ) async throws -> ExpenseResponse {
        let title = bankingTrimmedNonEmpty(request.titleOverride)
            ?? bankingTrimmedNonEmpty(transaction.merchant)
            ?? bankingTrimmedNonEmpty(transaction.descriptionText)
            ?? "Bank transaction"

        let expenseRequest = ExpenseRequest(
            title: title,
            amount: abs(transaction.amount),
            pillar: request.pillar,
            occurredOn: Self.dateFormatter.string(from: transaction.occurredOn),
            categoryId: request.categoryId
        )

        let expense = try await req.expensesService.createExpense(userId: userId, request: expenseRequest, on: req.db)

        transaction.status = BankTransactionStatus.imported.rawValue
        transaction.expenseId = UUID(uuidString: expense.id)
        try await transaction.save(on: req.db)
        return expense
    }

    /// Flags suggested transactions that likely duplicate an existing manual
    /// expense (same day, same amount) so the user can avoid double entry.
    func markDuplicates(_ transactions: [BankTransaction], userId: UUID, on db: any Database) async throws -> Set<UUID> {
        guard !transactions.isEmpty else { return [] }
        let dates = transactions.map(\.occurredOn)
        guard let minDate = dates.min(), let maxDate = dates.max() else { return [] }

        let windowStart = minDate.addingTimeInterval(-86400)
        let windowEnd = maxDate.addingTimeInterval(86400)
        let expenses = try await Expense.query(on: db)
            .filter(\.$user.$id == userId)
            .filter(\.$occurredOn >= windowStart)
            .filter(\.$occurredOn <= windowEnd)
            .all()

        var duplicates: Set<UUID> = []
        for tx in transactions {
            guard let txId = tx.id else { continue }
            let amount = abs(tx.amount)
            let match = expenses.contains { expense in
                abs(expense.amount - amount) < 0.005
                    && abs(expense.occurredOn.timeIntervalSince(tx.occurredOn)) <= 86400
            }
            if match {
                duplicates.insert(txId)
            }
        }
        return duplicates
    }
}
