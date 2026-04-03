import Fluent
import Vapor
import Foundation

final class RatiosTTMCache: Model, Content, @unchecked Sendable {
    static let schema = "ratios_ttm_cache"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "provider")
    var provider: String

    @Field(key: "symbol")
    var symbol: String

    @Field(key: "payload")
    var payload: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        provider: String,
        symbol: String,
        payload: String
    ) {
        self.id = id
        self.provider = provider
        self.symbol = symbol
        self.payload = payload
    }
}
