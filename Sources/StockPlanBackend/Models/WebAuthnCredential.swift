import Fluent
import Foundation
import Vapor

final class WebAuthnCredential: Model, Content, @unchecked Sendable {
    static let schema = "webauthn_credentials"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "credential_id")
    var credentialID: String

    @Field(key: "public_key")
    var publicKey: Data

    @Field(key: "sign_count")
    var signCount: UInt32

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        credentialID: String,
        publicKey: Data,
        signCount: UInt32 = 0
    ) {
        self.id = id
        $user.id = userID
        self.credentialID = credentialID
        self.publicKey = publicKey
        self.signCount = signCount
    }
}

final class WebAuthnLoginChallenge: Model, @unchecked Sendable {
    static let schema = "webauthn_login_challenges"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "challenge")
    var challenge: Data

    @Field(key: "expires_at")
    var expiresAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, challenge: Data, expiresAt: Date) {
        self.id = id
        self.challenge = challenge
        self.expiresAt = expiresAt
    }
}
