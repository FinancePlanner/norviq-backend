import Fluent

struct CreateMacroTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("macro_series_points")
            .id()
            .field("country", .string, .required)
            .field("series_key", .string, .required)
            .field("period_date", .string, .required)
            .field("value", .double, .required)
            .field("unit", .string, .required)
            .field("source", .string, .required)
            .field("vintage_date", .datetime, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "country", "series_key", "period_date", "source", "vintage_date")
            .create()

        try await database.createIndex(on: "macro_series_points", columns: ["country", "series_key", "period_date"])
        try await database.createIndex(on: "macro_series_points", columns: ["country", "series_key", "vintage_date"])

        try await database.schema("macro_snapshots")
            .id()
            .field("country", .string, .required)
            .field("as_of", .string, .required)
            .field("source", .string, .required)
            .field("payload", .string, .required)
            .field("fetched_at", .datetime, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "country", "as_of", "source")
            .create()

        try await database.createIndex(on: "macro_snapshots", columns: ["country", "fetched_at"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("macro_series_points").delete()
        try await database.schema("macro_snapshots").delete()
    }
}
