import Fluent
import Foundation
import Vapor

final class RatiosCache: Model, Content, @unchecked Sendable {
    static let schema = "ratios_cache"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "provider")
    var provider: String

    @Field(key: "symbol")
    var symbol: String

    @Field(key: "period")
    var period: String

    @Field(key: "limit")
    var limit: Int

    @Field(key: "payload")
    var payload: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        provider: String,
        symbol: String,
        period: String,
        limit: Int,
        payload: String
    ) {
        self.id = id
        self.provider = provider
        self.symbol = symbol
        self.period = period
        self.limit = limit
        self.payload = payload
    }
}
