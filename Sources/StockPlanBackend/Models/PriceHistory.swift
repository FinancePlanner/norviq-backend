import Fluent
import Vapor
import Foundation

final class PriceHistory: Model, Content, @unchecked Sendable {
    static let schema = "price_history"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "symbol")
    var symbol: String

    @Field(key: "date")
    var date: Date

    @Field(key: "open")
    var open: Double

    @Field(key: "high")
    var high: Double

    @Field(key: "low")
    var low: Double

    @Field(key: "close")
    var close: Double

    @Field(key: "volume")
    var volume: Int?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        symbol: String,
        date: Date,
        open: Double,
        high: Double,
        low: Double,
        close: Double,
        volume: Int? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.date = date
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
    }
}
