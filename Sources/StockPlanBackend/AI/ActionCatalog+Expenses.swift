import Foundation
import StockPlanShared
import Vapor

extension ActionCatalog {
    /// Moved here from AIChatToolRegistry unchanged in behaviour. These were the
    /// only writes any assistant surface had.
    static var expenseActions: [ActionDefinition] {
        [
            ActionDefinition(
                "add_expense",
                "Add a new expense.",
                properties: [
                    "title": OpenAIParameter(type: "string"),
                    "amount": OpenAIParameter(type: "number"),
                    "pillar": OpenAIParameter(
                        type: "string",
                        description: "one of fundamentals, futureYou, fun",
                        enumValues: ["fundamentals", "futureYou", "fun"]
                    ),
                    "occurred_on": OpenAIParameter(type: "string", description: "YYYY-MM-DD"),
                ],
                required: ["title", "amount", "pillar", "occurred_on"]
            ) { context, args, req in
                guard let title = args.string("title"), let amount = args.double("amount"),
                      let pillarRaw = args.string("pillar"), let occurredOn = args.string("occurred_on")
                else {
                    return errorPayload("missing required fields")
                }
                guard let pillar = BudgetPillar(rawValue: pillarRaw) else {
                    return errorPayload("invalid pillar; use fundamentals, futureYou, or fun")
                }
                // ExpensesService only rejects a negative or non-finite amount and
                // does not bound the title. The assistant's hand-written executor
                // was stricter, and it used to be the only path an assistant could
                // write an expense through — so these guards moved here with it
                // rather than being dropped. They now also cover /v1/ai/chat and MCP.
                guard amount.isFinite, amount > 0 else {
                    return errorPayload("amount must be a positive number")
                }
                let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanTitle.isEmpty, cleanTitle.count <= 200 else {
                    return errorPayload("title is required, and must be 200 characters or fewer")
                }
                let created = try await req.expensesService.createExpense(
                    userId: context.userId,
                    request: ExpenseRequest(title: cleanTitle, amount: amount, pillar: pillar, occurredOn: occurredOn),
                    on: req.db
                )
                return try encode(created)
            },

            ActionDefinition(
                "update_expense",
                "Update fields of an existing expense.",
                properties: [
                    "id": OpenAIParameter(type: "string"),
                    "title": OpenAIParameter(type: "string"),
                    "amount": OpenAIParameter(type: "number"),
                    "pillar": OpenAIParameter(type: "string", enumValues: ["fundamentals", "futureYou", "fun"]),
                    "occurred_on": OpenAIParameter(type: "string", description: "YYYY-MM-DD"),
                ],
                required: ["id"]
            ) { context, args, req in
                guard let idStr = args.string("id"), let id = UUID(uuidString: idStr) else {
                    return errorPayload("invalid id")
                }
                // Fetch existing to preserve unspecified fields.
                let existing = try await req.expensesService.getExpenses(
                    userId: context.userId, from: nil, to: nil, limit: 10000, cursor: nil, on: req.db
                ).items.first { $0.id == idStr }
                guard let existing else { return errorPayload("expense not found") }
                let pillar = args.string("pillar").flatMap { BudgetPillar(rawValue: $0) } ?? existing.pillar
                let updated = try await req.expensesService.updateExpense(
                    userId: context.userId, expenseId: id,
                    request: ExpenseRequest(
                        title: args.string("title") ?? existing.title,
                        amount: args.double("amount") ?? existing.amount,
                        pillar: pillar,
                        occurredOn: args.string("occurred_on") ?? existing.occurredOn,
                        categoryId: existing.categoryId
                    ),
                    on: req.db
                )
                return try encode(updated)
            },

            ActionDefinition(
                "delete_expense",
                "Delete an expense.",
                properties: ["id": OpenAIParameter(type: "string")],
                required: ["id"],
                destructive: true
            ) { context, args, req in
                guard let id = args.uuid("id") else { return errorPayload("invalid id") }
                try await req.expensesService.deleteExpense(userId: context.userId, expenseId: id, on: req.db)
                return statusPayload("deleted")
            },
        ]
    }
}
