import Fluent
import Foundation
import Vapor

final class Account: Model, Content, @unchecked Sendable {
    static let schema = "accounts"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @OptionalField(key: "portfolio_id")
    var portfolioId: UUID?

    @Field(key: "external_id")
    var externalId: String

    @Field(key: "broker")
    var broker: String

    @Field(key: "display_name")
    var displayName: String?

    @Field(key: "base_currency")
    var baseCurrency: String

    @OptionalField(key: "tax_wrapper")
    var taxWrapper: String?

    @OptionalField(key: "tax_jurisdiction")
    var taxJurisdiction: String?

    @OptionalField(key: "tax_owner_member_id")
    var taxOwnerMemberId: String?

    @OptionalField(key: "lot_selection_method")
    var lotSelectionMethod: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        externalId: String,
        broker: String,
        displayName: String? = nil,
        baseCurrency: String,
        portfolioId: UUID? = nil
    ) {
        self.id = id
        self.userId = userId
        self.portfolioId = portfolioId
        self.externalId = externalId
        self.broker = broker
        self.displayName = displayName
        self.baseCurrency = baseCurrency
    }
}
