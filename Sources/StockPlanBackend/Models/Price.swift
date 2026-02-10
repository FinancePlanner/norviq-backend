import Fluent
import Vapor
import Foundation

final class Price: Model, Content, @unchecked Sendable {
    static let schema = "prices"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "instrument_id")
    var instrumentId: UUID

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

    @Field(key: "currency")
    var currency: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        instrumentId: UUID,
        date: Date,
        open: Double,
        high: Double,
        low: Double,
        close: Double,
        volume: Int? = nil,
        currency: String
    ) {
        self.id = id
        self.instrumentId = instrumentId
        self.date = date
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
        self.currency = currency
    }
}
