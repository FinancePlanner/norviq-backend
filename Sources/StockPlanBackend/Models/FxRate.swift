import Fluent
import Vapor
import Foundation

final class FxRate: Model, Content, @unchecked Sendable {
    static let schema = "fx_rates"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "date")
    var date: Date

    @Field(key: "base")
    var base: String

    @Field(key: "quote")
    var quote: String

    @Field(key: "rate")
    var rate: Double

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(id: UUID? = nil, date: Date, base: String, quote: String, rate: Double) {
        self.id = id
        self.date = date
        self.base = base
        self.quote = quote
        self.rate = rate
    }
}
