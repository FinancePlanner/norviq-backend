import Fluent
import Foundation

final class MarketPriceBar: Model, @unchecked Sendable {
    static let schema = "market_price_bars"
    @ID(key: .id) var id: UUID?
    @Field(key: "instrument_key") var instrumentKey: String
    @Field(key: "date") var date: Date
    @Field(key: "open") var open: Double
    @Field(key: "high") var high: Double
    @Field(key: "low") var low: Double
    @Field(key: "close") var close: Double
    @Field(key: "adjusted_close") var adjustedClose: Double
    @OptionalField(key: "volume") var volume: Double?
    @Field(key: "currency") var currency: String
    @Field(key: "provider") var provider: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}
