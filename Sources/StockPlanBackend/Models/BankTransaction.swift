import Fluent
import Foundation

/// A synced bank transaction. Staged here as a "suggestion" the user reviews
/// before it becomes an expense — imports are never automatic, to avoid
/// double-counting budgets.
final class BankTransaction: Model, @unchecked Sendable {
    static let schema = "bank_transactions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "account_id")
    var accountId: UUID

    /// Denormalized for user-scoped queries without a join.
    @Field(key: "user_id")
    var userId: UUID

    /// Provider's transaction id — the primary dedupe key.
    @Field(key: "provider_tx_id")
    var providerTxId: String

    /// Fallback dedupe hash (account + date + amount + normalized description)
    /// for providers whose ids are unstable.
    @Field(key: "dedupe_hash")
    var dedupeHash: String

    @Field(key: "amount")
    var amount: Double

    @OptionalField(key: "currency")
    var currency: String?

    @Field(key: "occurred_on")
    var occurredOn: Date

    @OptionalField(key: "merchant")
    var merchant: String?

    @OptionalField(key: "description_text")
    var descriptionText: String?

    @Field(key: "pending")
    var pending: Bool

    /// "suggested" | "imported" | "dismissed".
    @Field(key: "status")
    var status: String

    @OptionalField(key: "provider_category")
    var providerCategory: String?

    /// Set once imported; links to the created expense.
    @OptionalField(key: "expense_id")
    var expenseId: UUID?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        accountId: UUID,
        userId: UUID,
        providerTxId: String,
        dedupeHash: String,
        amount: Double,
        currency: String? = nil,
        occurredOn: Date,
        merchant: String? = nil,
        descriptionText: String? = nil,
        pending: Bool = false,
        status: String = "suggested",
        providerCategory: String? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.userId = userId
        self.providerTxId = providerTxId
        self.dedupeHash = dedupeHash
        self.amount = amount
        self.currency = currency
        self.occurredOn = occurredOn
        self.merchant = merchant
        self.descriptionText = descriptionText
        self.pending = pending
        self.status = status
        self.providerCategory = providerCategory
    }
}
