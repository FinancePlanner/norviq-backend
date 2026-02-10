import Fluent
import Vapor
import Foundation

final class Account: Model, Content, @unchecked Sendable {
    static let schema = "accounts"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "external_id")
    var externalId: String

    @Field(key: "broker")
    var broker: String

    @Field(key: "display_name")
    var displayName: String?

    @Field(key: "base_currency")
    var baseCurrency: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        userId: UUID,
        externalId: String,
        broker: String,
        displayName: String? = nil,
        baseCurrency: String
    ) {
        self.id = id
        self.userId = userId
        self.externalId = externalId
        self.broker = broker
        self.displayName = displayName
        self.baseCurrency = baseCurrency
    }
}
