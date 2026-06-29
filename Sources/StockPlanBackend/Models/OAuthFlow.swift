import Fluent
import Foundation

enum OAuthFlowPurpose: String {
    case login
    case link
}

final class OAuthFlow: Model, @unchecked Sendable {
    static let schema = "oauth_flows"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "provider")
    var provider: String

    @Field(key: "state")
    var state: String

    @Field(key: "nonce")
    var nonce: String

    @Field(key: "code_verifier")
    var codeVerifier: String

    @Field(key: "redirect_uri")
    var redirectURI: String

    @Field(key: "purpose")
    var purpose: String

    @OptionalField(key: "user_id")
    var userId: UUID?

    @Field(key: "expires_at")
    var expiresAt: Date

    @OptionalField(key: "used_at")
    var usedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        provider: String,
        state: String,
        nonce: String,
        codeVerifier: String,
        redirectURI: String,
        purpose: String = OAuthFlowPurpose.login.rawValue,
        userId: UUID? = nil,
        expiresAt: Date
    ) {
        self.id = id
        self.provider = provider
        self.state = state
        self.nonce = nonce
        self.codeVerifier = codeVerifier
        self.redirectURI = redirectURI
        self.purpose = purpose
        self.userId = userId
        self.expiresAt = expiresAt
    }
}
