import Fluent
import Foundation

/// A single authorization-code flow. Created at /authorize (status `pending`),
/// bound to a user and issued a code hash at consent approval (`approved`),
/// then consumed once at /token (`consumed`). Short-lived (~10 min).
final class OAuthAuthorizationFlow: Model, @unchecked Sendable {
    static let schema = "oauth_authorization_flows"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "client_id")
    var clientID: String

    @OptionalField(key: "user_id")
    var userID: UUID?

    @Field(key: "scopes")
    var scopes: [String]

    @Field(key: "redirect_uri")
    var redirectURI: String

    @OptionalField(key: "state")
    var state: String?

    /// PKCE code challenge (S256 only).
    @Field(key: "code_challenge")
    var codeChallenge: String

    /// SHA-256 hash of the issued authorization code (nil until approved).
    @OptionalField(key: "code_hash")
    var codeHash: String?

    /// pending | approved | consumed | denied
    @Field(key: "status")
    var status: String

    @Field(key: "expires_at")
    var expiresAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        clientID: String,
        scopes: [String],
        redirectURI: String,
        state: String?,
        codeChallenge: String,
        expiresAt: Date,
        status: String = "pending"
    ) {
        self.id = id
        self.clientID = clientID
        self.scopes = scopes
        self.redirectURI = redirectURI
        self.state = state
        self.codeChallenge = codeChallenge
        self.expiresAt = expiresAt
        self.status = status
    }
}

extension OAuthAuthorizationFlow {
    var isPending: Bool {
        status == "pending" && expiresAt > Date()
    }

    var isApproved: Bool {
        status == "approved" && expiresAt > Date()
    }
}
