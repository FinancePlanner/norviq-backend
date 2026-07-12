import Fluent
import Foundation

/// A single account within a bank connection.
final class BankAccount: Model, @unchecked Sendable {
    static let schema = "bank_accounts"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "connection_id")
    var connectionId: UUID

    /// Provider's account id (Plaid account_id).
    @Field(key: "provider_account_id")
    var providerAccountId: String

    @Field(key: "name")
    var name: String

    @OptionalField(key: "mask")
    var mask: String?

    @OptionalField(key: "currency")
    var currency: String?

    @OptionalField(key: "type")
    var type: String?

    @OptionalField(key: "balance")
    var balance: Double?

    @OptionalField(key: "balance_as_of")
    var balanceAsOf: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        connectionId: UUID,
        providerAccountId: String,
        name: String,
        mask: String? = nil,
        currency: String? = nil,
        type: String? = nil,
        balance: Double? = nil,
        balanceAsOf: Date? = nil
    ) {
        self.id = id
        self.connectionId = connectionId
        self.providerAccountId = providerAccountId
        self.name = name
        self.mask = mask
        self.currency = currency
        self.type = type
        self.balance = balance
        self.balanceAsOf = balanceAsOf
    }
}
