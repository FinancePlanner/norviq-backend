import Fluent
import Foundation
import Vapor

final class PushDevice: Model, Content, @unchecked Sendable {
    static let schema = "push_devices"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "device_token")
    var deviceToken: String

    @Field(key: "platform")
    var platform: String

    @Field(key: "apns_environment")
    var apnsEnvironment: String

    @Field(key: "authorization_status")
    var authorizationStatus: String

    @Field(key: "is_active")
    var isActive: Bool

    @Field(key: "last_seen_at")
    var lastSeenAt: Date

    @Field(key: "capabilities_json")
    var capabilitiesJSON: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        deviceToken: String,
        platform: String,
        apnsEnvironment: String,
        authorizationStatus: String,
        isActive: Bool = true,
        lastSeenAt: Date = Date(),
        capabilitiesJSON: String = "[]"
    ) {
        self.id = id
        self.userId = userId
        self.deviceToken = deviceToken
        self.platform = platform
        self.apnsEnvironment = apnsEnvironment
        self.authorizationStatus = authorizationStatus
        self.isActive = isActive
        self.lastSeenAt = lastSeenAt
        self.capabilitiesJSON = capabilitiesJSON
    }
}
