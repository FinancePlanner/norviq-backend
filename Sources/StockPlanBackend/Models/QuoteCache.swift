import Fluent
import Foundation
import Vapor

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

    @OptionalField(key: "change")
    var change: Double?

    @OptionalField(key: "percent_change")
    var percentChange: Double?

    @OptionalField(key: "high")
    var high: Double?

    @OptionalField(key: "low")
    var low: Double?

    @OptionalField(key: "open")
    var open: Double?

    @OptionalField(key: "previous_close")
    var previousClose: Double?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        provider: String,
        symbol: String,
        currency: String,
        price: Double,
        asOf: Date,
        change: Double? = nil,
        percentChange: Double? = nil,
        high: Double? = nil,
        low: Double? = nil,
        open: Double? = nil,
        previousClose: Double? = nil
    ) {
        self.id = id
        self.provider = provider
        self.symbol = symbol
        self.currency = currency
        self.price = price
        self.asOf = asOf
        self.change = change
        self.percentChange = percentChange
        self.high = high
        self.low = low
        self.open = open
        self.previousClose = previousClose
    }
}
