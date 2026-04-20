import Fluent

struct CreateRecurringTemplatesTable: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(RecurringTemplate.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("title", .string, .required)
            .field("amount", .double, .required)
            .field("pillar", .string, .required)
            .field("category_id", .uuid, .references(ExpenseCategory.schema, "id", onDelete: .setNull))
            .field("frequency", .string, .required)
            .field("split_mode", .enum(.init(name: "expense_split_mode")), .required)
            .field("user_share_percent", .double, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(RecurringTemplate.schema).delete()
    }
}
