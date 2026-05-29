import Fluent
import Foundation
import StockPlanShared
import Vapor

final class CryptoWatchlistItem: Model, Content, @unchecked Sendable {
    static let schema = "crypto_watchlist_items"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "symbol")
    var symbol: String

    @Field(key: "name")
    var name: String

    @OptionalField(key: "note")
    var note: String?

    @Field(key: "status")
    var status: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        symbol: String,
        name: String,
        note: String? = nil,
        status: WatchlistStatus = .active
    ) {
        self.id = id
        self.userId = userId
        self.symbol = symbol
        self.name = name
        self.note = note
        self.status = status.rawValue
    }
}
