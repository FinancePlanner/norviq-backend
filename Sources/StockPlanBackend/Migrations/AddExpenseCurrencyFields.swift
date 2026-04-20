import Fluent

struct AddExpenseCurrencyFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Expense.schema)
            .field("foreign_amount", .double)
            .field("foreign_currency", .string)
            .field("exchange_rate", .double)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Expense.schema)
            .deleteField("exchange_rate")
            .deleteField("foreign_currency")
            .deleteField("foreign_amount")
            .update()
    }
}
