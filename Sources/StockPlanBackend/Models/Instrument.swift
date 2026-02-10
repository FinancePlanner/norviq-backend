import Fluent
import Vapor
import Foundation

final class Instrument: Model, Content, @unchecked Sendable {
    static let schema = "instruments"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "conid")
    var conid: String

    @Field(key: "symbol")
    var symbol: String

    @Field(key: "exchange")
    var exchange: String

    @Field(key: "currency")
    var currency: String

    @Field(key: "name")
    var name: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        conid: String,
        symbol: String,
        exchange: String,
        currency: String,
        name: String? = nil
    ) {
        self.id = id
        self.conid = conid
        self.symbol = symbol
        self.exchange = exchange
        self.currency = currency
        self.name = name
    }
}
