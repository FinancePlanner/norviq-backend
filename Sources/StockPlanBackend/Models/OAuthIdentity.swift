import Fluent
import Foundation

final class OAuthIdentity: Model, @unchecked Sendable {
    static let schema = "oauth_identities"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "provider")
    var provider: String

    @Field(key: "provider_user_id")
    var providerUserID: String

    @OptionalField(key: "email")
    var email: String?

    @Field(key: "email_verified")
    var emailVerified: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        userID: UUID,
        provider: String,
        providerUserID: String,
        email: String?,
        emailVerified: Bool
    ) {
        self.id = id
        self.$user.id = userID
        self.provider = provider
        self.providerUserID = providerUserID
        self.email = email
        self.emailVerified = emailVerified
    }
}
