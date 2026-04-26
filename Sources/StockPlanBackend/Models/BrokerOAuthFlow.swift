import Fluent
import Foundation

final class BrokerOAuthFlow: Model, @unchecked Sendable {
    static let schema = "broker_oauth_flows"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "provider")
    var provider: String

    @Field(key: "state")
    var state: String

    @Field(key: "redirect_uri")
    var redirectURI: String

    @OptionalField(key: "portfolio_list_id")
    var portfolioListId: UUID?

    @Field(key: "expires_at")
    var expiresAt: Date

    @OptionalField(key: "used_at")
    var usedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        provider: String,
        state: String,
        redirectURI: String,
        portfolioListId: UUID? = nil,
        expiresAt: Date,
        usedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.provider = provider
        self.state = state
        self.redirectURI = redirectURI
        self.portfolioListId = portfolioListId
        self.expiresAt = expiresAt
        self.usedAt = usedAt
    }
}
