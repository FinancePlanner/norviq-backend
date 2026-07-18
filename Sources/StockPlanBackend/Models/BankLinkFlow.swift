import Fluent
import Foundation

/// Pending hosted-link flow (GoCardless). Ties the callback `reference` back to
/// the user and requisition, and remembers where to redirect the client after
/// consent. Single-use and time-limited, mirroring `BrokerOAuthFlow`.
final class BankLinkFlow: Model, @unchecked Sendable {
    static let schema = "bank_link_flows"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "provider")
    var provider: String

    /// Random reference we set on the requisition and receive back on callback.
    @Field(key: "reference")
    var reference: String

    /// Provider's requisition id.
    @Field(key: "requisition_id")
    var requisitionId: String

    @OptionalField(key: "institution_id")
    var institutionId: String?

    /// App/web URL to redirect back to once the connection is created.
    @Field(key: "app_redirect_uri")
    var appRedirectURI: String

    @Field(key: "expires_at")
    var expiresAt: Date

    @OptionalField(key: "used_at")
    var usedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        provider: String,
        reference: String,
        requisitionId: String,
        institutionId: String?,
        appRedirectURI: String,
        expiresAt: Date
    ) {
        self.id = id
        self.userId = userId
        self.provider = provider
        self.reference = reference
        self.requisitionId = requisitionId
        self.institutionId = institutionId
        self.appRedirectURI = appRedirectURI
        self.expiresAt = expiresAt
    }
}
