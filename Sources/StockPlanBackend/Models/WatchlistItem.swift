import Fluent
import Foundation
import StockPlanShared
import Vapor

final class WatchlistItem: Model, Content, @unchecked Sendable {
    static let schema = "watchlist_items"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "watchlist_list_id")
    var watchlistListId: UUID

    @Field(key: "symbol")
    var symbol: String

    @OptionalField(key: "note")
    var note: String?

    @Field(key: "status")
    var status: String

    @OptionalField(key: "last_reviewed_at")
    var lastReviewedAt: Date?

    @OptionalField(key: "next_review_at")
    var nextReviewAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        watchlistListId: UUID,
        symbol: String,
        note: String? = nil,
        status: WatchlistStatus = .active,
        lastReviewedAt: Date? = nil,
        nextReviewAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.watchlistListId = watchlistListId
        self.symbol = symbol
        self.note = note
        self.status = status.rawValue
        self.lastReviewedAt = lastReviewedAt
        self.nextReviewAt = nextReviewAt
    }
}
