import Fluent
import Foundation

/// A dynamically-registered (RFC 7591) OAuth 2.1 public client. Redirect URIs are
/// stored per-client and matched exactly at /authorize — they are NOT routed
/// through the social-login OAUTH_ALLOWED_REDIRECT_URIS env allow-list.
final class OAuthClient: Model, @unchecked Sendable {
    static let schema = "oauth_clients"

    @ID(key: .id)
    var id: UUID?

    /// Public client identifier handed to the client at registration.
    @Field(key: "client_id")
    var clientID: String

    @Field(key: "client_name")
    var clientName: String

    @Field(key: "redirect_uris")
    var redirectURIs: [String]

    /// Only "none" is supported: public clients authenticate with PKCE, no secret.
    @Field(key: "token_endpoint_auth_method")
    var tokenEndpointAuthMethod: String

    @Field(key: "last_used_at")
    var lastUsedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        clientID: String,
        clientName: String,
        redirectURIs: [String],
        tokenEndpointAuthMethod: String = "none"
    ) {
        self.id = id
        self.clientID = clientID
        self.clientName = clientName
        self.redirectURIs = redirectURIs
        self.tokenEndpointAuthMethod = tokenEndpointAuthMethod
    }
}
