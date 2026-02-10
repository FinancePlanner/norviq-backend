import Fluent
import Vapor
import Foundation

final class Stock: Model, Content, @unchecked Sendable {
    static let schema = "stocks"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "symbol")
    var symbol: String

    @Field(key: "shares")
    var shares: Double

    @Field(key: "buy_price")
    var buyPrice: Double

    @Field(key: "buy_date")
    var buyDate: Date

    @Field(key: "notes")
    var notes: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        userId: UUID,
        symbol: String,
        shares: Double,
        buyPrice: Double,
        buyDate: Date,
        notes: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.symbol = symbol
        self.shares = shares
        self.buyPrice = buyPrice
        self.buyDate = buyDate
        self.notes = notes
    }
}
