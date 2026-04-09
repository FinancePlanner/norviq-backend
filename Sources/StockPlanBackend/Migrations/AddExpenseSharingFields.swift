import Fluent
import FluentSQL
import SQLKit
import StockPlanShared

private struct EnumExistsResult: Codable {
    let exists: Bool
}

struct AddExpenseSharingFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let splitModeEnum: DatabaseSchema.DataType

        if let sql = database as? any SQLDatabase {
            let enumExists = try await sql.raw("""
                SELECT EXISTS (
                    SELECT 1 FROM pg_type WHERE typname = 'expense_split_mode'
                )
                """)
                .first(decoding: EnumExistsResult.self)

            if enumExists?.exists == true {
                // Enum already exists, read it
                splitModeEnum = try await database.enum("expense_split_mode").read()
            } else {
                // Create the enum
                splitModeEnum = try await database.enum("expense_split_mode")
                    .case(ExpenseSplitMode.personal.rawValue)
                    .case(ExpenseSplitMode.shared.rawValue)
                    .create()
            }
        } else {
            // Fallback for non-SQL databases (if applicable)
            splitModeEnum = try await database.enum("expense_split_mode")
                .case(ExpenseSplitMode.personal.rawValue)
                .case(ExpenseSplitMode.shared.rawValue)
                .create()
        }

        try await database.schema(BudgetPlanItem.schema)
            .field("split_mode", splitModeEnum, .required, .sql(.default(SQLRaw("'personal'::expense_split_mode"))))
            .field("user_share_percent", .double, .required, .sql(.default(SQLRaw("100"))))
            .update()

        try await database.schema(Expense.schema)
            .field("split_mode", splitModeEnum, .required, .sql(.default(SQLRaw("'personal'::expense_split_mode"))))
            .field("user_share_percent", .double, .required, .sql(.default(SQLRaw("100"))))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Expense.schema)
            .deleteField("user_share_percent")
            .deleteField("split_mode")
            .update()

        try await database.schema(BudgetPlanItem.schema)
            .deleteField("user_share_percent")
            .deleteField("split_mode")
            .update()

        try await database.enum("expense_split_mode").delete()
    }
}
