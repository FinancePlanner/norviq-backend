import Fluent
import Vapor
import Foundation

final class Transaction: Model, Content, @unchecked Sendable {
    static let schema = "transactions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "account_id")
    var accountId: UUID

    @Field(key: "instrument_id")
    var instrumentId: UUID

    @Field(key: "external_id")
    var externalId: String?

    @Field(key: "type")
    var type: String

    @Field(key: "quantity")
    var quantity: Double?

    @Field(key: "price")
    var price: Double?

    @Field(key: "currency")
    var currency: String

    @Field(key: "trade_date")
    var tradeDate: Date

    @Field(key: "settle_date")
    var settleDate: Date?

    @Field(key: "fees")
    var fees: Double?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        accountId: UUID,
        instrumentId: UUID,
        externalId: String? = nil,
        type: String,
        quantity: Double? = nil,
        price: Double? = nil,
        currency: String,
        tradeDate: Date,
        settleDate: Date? = nil,
        fees: Double? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.instrumentId = instrumentId
        self.externalId = externalId
        self.type = type
        self.quantity = quantity
        self.price = price
        self.currency = currency
        self.tradeDate = tradeDate
        self.settleDate = settleDate
        self.fees = fees
    }
}
