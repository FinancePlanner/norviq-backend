import Fluent
import Vapor
import Foundation

final class WatchlistItem: Model, Content, @unchecked Sendable {
    static let schema = "watchlist_items"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "symbol")
    var symbol: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(id: UUID? = nil, userId: UUID, symbol: String) {
        self.id = id
        self.userId = userId
        self.symbol = symbol
    }
}
