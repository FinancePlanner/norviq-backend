import Fluent
import FluentSQL

/// "Find friends from Facebook": the opt-out switch and the friend ids
/// Facebook granted at the last import. Both rows go with the user.
struct AddSocialFacebookImport: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("social_settings")
            .field("discoverable_by_facebook", .bool, .required, .sql(.default(SQLRaw("true"))))
            .update()
        try await database.schema("social_facebook_friends")
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("facebook_id", .string, .required)
            .compositeIdentifier(over: "user_id", "facebook_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("social_facebook_friends").delete()
        try await database.schema("social_settings").deleteField("discoverable_by_facebook").update()
    }
}
