import Fluent
import Vapor
import Foundation

final class Position: Model, Content, @unchecked Sendable {
    static let schema = "positions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "account_id")
    var accountId: UUID

    @Field(key: "instrument_id")
    var instrumentId: UUID

    @Field(key: "quantity")
    var quantity: Double

    @Field(key: "average_cost")
    var averageCost: Double

    @Field(key: "currency")
    var currency: String

    @Field(key: "market_value")
    var marketValue: Double?

    @Field(key: "last_price")
    var lastPrice: Double?

    @Field(key: "last_price_date")
    var lastPriceDate: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        accountId: UUID,
        instrumentId: UUID,
        quantity: Double,
        averageCost: Double,
        currency: String,
        marketValue: Double? = nil,
        lastPrice: Double? = nil,
        lastPriceDate: Date? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.instrumentId = instrumentId
        self.quantity = quantity
        self.averageCost = averageCost
        self.currency = currency
        self.marketValue = marketValue
        self.lastPrice = lastPrice
        self.lastPriceDate = lastPriceDate
    }
}
