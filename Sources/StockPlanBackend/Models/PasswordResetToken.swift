import Fluent
import Foundation

final class PasswordResetToken: Model, @unchecked Sendable {
    static let schema = "password_reset_tokens"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "code_hash")
    var codeHash: String

    @Field(key: "expires_at")
    var expiresAt: Date

    @Field(key: "used_at")
    var usedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        userId: UUID,
        codeHash: String,
        expiresAt: Date,
        usedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.codeHash = codeHash
        self.expiresAt = expiresAt
        self.usedAt = usedAt
    }
}
