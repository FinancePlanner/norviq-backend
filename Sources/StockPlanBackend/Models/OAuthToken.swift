import Fluent
import Foundation

/// An issued OAuth access+refresh token pair. Refresh tokens rotate on use;
/// `replacedBy` forms a chain so a replayed (already-rotated) refresh token is
/// detected and the whole family revoked.
final class OAuthToken: Model, @unchecked Sendable {
    static let schema = "oauth_tokens"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "client_id")
    var clientID: String

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "access_token_hash")
    var accessTokenHash: String

    @Field(key: "refresh_token_hash")
    var refreshTokenHash: String

    @Field(key: "scopes")
    var scopes: [String]

    @Field(key: "access_expires_at")
    var accessExpiresAt: Date

    @Field(key: "refresh_expires_at")
    var refreshExpiresAt: Date

    @OptionalField(key: "revoked_at")
    var revokedAt: Date?

    /// ID of the token that superseded this one via refresh rotation.
    @OptionalField(key: "replaced_by")
    var replacedBy: UUID?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        clientID: String,
        userID: UUID,
        accessTokenHash: String,
        refreshTokenHash: String,
        scopes: [String],
        accessExpiresAt: Date,
        refreshExpiresAt: Date
    ) {
        self.id = id
        self.clientID = clientID
        self.userID = userID
        self.accessTokenHash = accessTokenHash
        self.refreshTokenHash = refreshTokenHash
        self.scopes = scopes
        self.accessExpiresAt = accessExpiresAt
        self.refreshExpiresAt = refreshExpiresAt
    }
}

extension OAuthToken {
    var accessActive: Bool {
        revokedAt == nil && accessExpiresAt > Date()
    }
}
