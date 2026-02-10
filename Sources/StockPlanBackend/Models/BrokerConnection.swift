import Fluent
import Foundation

final class BrokerConnection: Model, @unchecked Sendable {
    static let schema = "broker_connections"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "provider")
    var provider: String

    @Field(key: "external_id")
    var externalId: String?

    @Field(key: "access_token")
    var accessToken: String?

    @Field(key: "refresh_token")
    var refreshToken: String?

    @Field(key: "expires_at")
    var expiresAt: Date?

    @Field(key: "status")
    var status: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        userId: UUID,
        provider: String,
        externalId: String? = nil,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        status: String
    ) {
        self.id = id
        self.userId = userId
        self.provider = provider
        self.externalId = externalId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.status = status
    }
}
