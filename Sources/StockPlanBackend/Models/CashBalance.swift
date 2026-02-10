import Fluent
import Vapor
import Foundation

final class CashBalance: Model, Content, @unchecked Sendable {
    static let schema = "cash_balances"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "account_id")
    var accountId: UUID

    @Field(key: "currency")
    var currency: String

    @Field(key: "balance")
    var balance: Double

    @Field(key: "as_of")
    var asOf: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        accountId: UUID,
        currency: String,
        balance: Double,
        asOf: Date
    ) {
        self.id = id
        self.accountId = accountId
        self.currency = currency
        self.balance = balance
        self.asOf = asOf
    }
}
