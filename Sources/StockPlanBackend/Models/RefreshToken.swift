import Fluent
import Foundation

final class RefreshToken: Model, @unchecked Sendable {
    static let schema = "refresh_tokens"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "token_hash")
    var tokenHash: String

    @Field(key: "expires_at")
    var expiresAt: Date

    @Field(key: "revoked_at")
    var revokedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        userId: UUID,
        tokenHash: String,
        expiresAt: Date,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.tokenHash = tokenHash
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
    }
}
