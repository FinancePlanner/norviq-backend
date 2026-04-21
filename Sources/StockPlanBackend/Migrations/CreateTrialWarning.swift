import Fluent

struct CreateTrialWarning: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let warningTypeEnum = try await database.enum("trial_warning_type")
            .case("expiring_soon")
            .case("expired")
            .create()

        try await database.schema("trial_warnings")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("warning_type", warningTypeEnum, .required)
            .field("sent_at", .datetime, .required)
            .field("created_at", .datetime)
            .unique(on: "user_id", "warning_type")
            .create()

        try await database.createIndex(on: "trial_warnings", columns: ["user_id"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("trial_warnings").delete()
        try await database.enum("trial_warning_type").delete()
    }
}
