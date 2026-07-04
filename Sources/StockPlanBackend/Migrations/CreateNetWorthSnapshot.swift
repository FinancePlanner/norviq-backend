import Fluent

struct CreateNetWorthSnapshot: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("net_worth_snapshots")
            .id()
            .field("dedupe_key", .string, .required)
            .field("total_value", .double)
            .field("currency", .string, .required)
            .field("captured_at", .datetime, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "dedupe_key")
            .create()

        try await database.createIndex(on: "net_worth_snapshots", columns: ["captured_at"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("net_worth_snapshots").delete()
    }
}
