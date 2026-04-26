import Fluent
import Foundation
import Vapor

final class CryptoPortfolioItem: Model, Content, @unchecked Sendable {
    static let schema = "crypto_portfolio_items"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "symbol")
    var symbol: String

    @Field(key: "name")
    var name: String

    @Field(key: "quantity")
    var quantity: Double

    @Field(key: "average_buy_price")
    var averageBuyPrice: Double

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        symbol: String,
        name: String,
        quantity: Double,
        averageBuyPrice: Double
    ) {
        self.id = id
        self.userId = userId
        self.symbol = symbol
        self.name = name
        self.quantity = quantity
        self.averageBuyPrice = averageBuyPrice
    }
}
