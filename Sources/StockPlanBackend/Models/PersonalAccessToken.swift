import Fluent
import Foundation

final class PersonalAccessToken: Model, @unchecked Sendable {
    static let schema = "personal_access_tokens"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "name")
    var name: String

    @Field(key: "token_hash")
    var tokenHash: String

    @Field(key: "scopes")
    var scopes: [String]

    @Field(key: "last_used_at")
    var lastUsedAt: Date?

    @Field(key: "expires_at")
    var expiresAt: Date

    @Field(key: "revoked_at")
    var revokedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        name: String,
        tokenHash: String,
        scopes: [String],
        expiresAt: Date,
        lastUsedAt: Date? = nil,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.name = name
        self.tokenHash = tokenHash
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.lastUsedAt = lastUsedAt
        self.revokedAt = revokedAt
    }
}

extension PersonalAccessToken {
    var isActive: Bool {
        revokedAt == nil && expiresAt > Date()
    }
}
