import Fluent
import Vapor
import Foundation

final class QuoteCache: Model, Content, @unchecked Sendable {
    static let schema = "quote_cache"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "provider")
    var provider: String

    @Field(key: "symbol")
    var symbol: String

    @Field(key: "currency")
    var currency: String

    @Field(key: "price")
    var price: Double

    @Field(key: "as_of")
    var asOf: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        provider: String,
        symbol: String,
        currency: String,
        price: Double,
        asOf: Date
    ) {
        self.id = id
        self.provider = provider
        self.symbol = symbol
        self.currency = currency
        self.price = price
        self.asOf = asOf
    }
}
