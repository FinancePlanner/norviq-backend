import Fluent
import Foundation
import Vapor

final class PortfolioList: Model, Content, @unchecked Sendable {
    static let schema = "portfolio_lists"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "name")
    var name: String

    @Field(key: "is_default")
    var isDefault: Bool

    @Field(key: "purpose")
    var purpose: String

    @Field(key: "ownership")
    var ownership: String

    @Field(key: "mode")
    var mode: String

    @Field(key: "base_currency")
    var baseCurrency: String

    @OptionalField(key: "source_portfolio_id")
    var sourcePortfolioId: UUID?

    @OptionalField(key: "cloned_at")
    var clonedAt: Date?

    @OptionalField(key: "archived_at")
    var archivedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        name: String,
        isDefault: Bool = false,
        purpose: String = "personal",
        ownership: String = "individual",
        mode: String = "actual",
        baseCurrency: String = "USD",
        sourcePortfolioId: UUID? = nil,
        clonedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.name = name
        self.isDefault = isDefault
        self.purpose = purpose
        self.ownership = ownership
        self.mode = mode
        self.baseCurrency = baseCurrency
        self.sourcePortfolioId = sourcePortfolioId
        self.clonedAt = clonedAt
    }
}
