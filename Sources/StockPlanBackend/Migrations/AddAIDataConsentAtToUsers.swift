import Fluent

/// When the user agreed to send their financial context to third-party AI
/// providers. Null means no consent; see `AIConsent`.
struct AddAIDataConsentAtToUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("ai_data_consent_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("ai_data_consent_at")
            .update()
    }
}
