import Fluent

struct CreateDividend: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("dividends")
            .id()
            .field("account_id", .uuid, .required)
            .field("instrument_id", .uuid, .required)
            .field("external_id", .string)
            .field("amount", .double, .required)
            .field("currency", .string, .required)
            .field("ex_date", .date)
            .field("pay_date", .date, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "account_id", "external_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("dividends").delete()
    }
}
