import Fluent
import Foundation

/// A user's connection to a bank via an aggregator (Plaid, GoCardless). Access
/// credentials are stored encrypted at rest via `TokenEncryptionService`.
final class BankConnection: Model, @unchecked Sendable {
    static let schema = "bank_connections"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    /// Aggregator id: "plaid" or "gocardless".
    @Field(key: "provider")
    var provider: String

    @OptionalField(key: "institution_id")
    var institutionId: String?

    @OptionalField(key: "institution_name")
    var institutionName: String?

    /// Provider's stable connection id (Plaid item_id / GoCardless requisition id).
    @Field(key: "provider_item_id")
    var providerItemId: String

    /// Encrypted access token (Plaid). Nil for providers that don't need one.
    @OptionalField(key: "access_token_enc")
    var accessTokenEnc: String?

    /// Incremental sync cursor (Plaid /transactions/sync).
    @OptionalField(key: "sync_cursor")
    var syncCursor: String?

    @Field(key: "status")
    var status: String

    /// When consent expires (GoCardless 90-day). Nil for Plaid.
    @OptionalField(key: "consent_expires_at")
    var consentExpiresAt: Date?

    @OptionalField(key: "last_synced_at")
    var lastSyncedAt: Date?

    @OptionalField(key: "last_sync_status")
    var lastSyncStatus: String?

    @OptionalField(key: "last_sync_error")
    var lastSyncError: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        provider: String,
        institutionId: String? = nil,
        institutionName: String? = nil,
        providerItemId: String,
        accessTokenEnc: String? = nil,
        status: String,
        consentExpiresAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.provider = provider
        self.institutionId = institutionId
        self.institutionName = institutionName
        self.providerItemId = providerItemId
        self.accessTokenEnc = accessTokenEnc
        self.status = status
        self.consentExpiresAt = consentExpiresAt
    }
}
