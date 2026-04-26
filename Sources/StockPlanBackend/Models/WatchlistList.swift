import Fluent
import Foundation
import Vapor

final class WatchlistList: Model, Content, @unchecked Sendable {
    static let schema = "watchlist_lists"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "name")
    var name: String

    @Field(key: "is_default")
    var isDefault: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        name: String,
        isDefault: Bool = false
    ) {
        self.id = id
        self.userId = userId
        self.name = name
        self.isDefault = isDefault
    }
}
