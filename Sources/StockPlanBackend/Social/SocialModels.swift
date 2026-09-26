import Fluent
import Foundation

/// A pending friend request. Accepting it deletes the row and writes two
/// `SocialFriendship` rows, one per direction.
final class SocialFriendRequest: Model, @unchecked Sendable {
    static let schema = "social_friend_requests"

    @ID(key: .id) var id: UUID?
    @Field(key: "from_user_id") var fromUserId: UUID
    @Field(key: "to_user_id") var toUserId: UUID
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(fromUserId: UUID, toUserId: UUID) {
        self.fromUserId = fromUserId
        self.toUserId = toUserId
    }
}

/// One direction of a mutual friendship. Stored both ways so "my friends" is
/// a single indexed lookup on `user_id`.
final class SocialFriendship: Model, @unchecked Sendable {
    static let schema = "social_friendships"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "friend_id") var friendId: UUID
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userId: UUID, friendId: UUID) {
        self.userId = userId
        self.friendId = friendId
    }
}

final class SocialBlock: Model, @unchecked Sendable {
    static let schema = "social_blocks"

    @ID(key: .id) var id: UUID?
    @Field(key: "blocker_id") var blockerId: UUID
    @Field(key: "blocked_id") var blockedId: UUID
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(blockerId: UUID, blockedId: UUID) {
        self.blockerId = blockerId
        self.blockedId = blockedId
    }
}

/// A report waiting for human review (App Review Guideline 1.2). The target is
/// not a foreign key: reports must outlive a deleted message or account.
final class SocialReport: Model, @unchecked Sendable {
    static let schema = "social_reports"

    @ID(key: .id) var id: UUID?
    @Field(key: "reporter_id") var reporterId: UUID
    @Field(key: "target_type") var targetType: String
    @Field(key: "target_id") var targetId: String
    @Field(key: "reason") var reason: String
    @OptionalField(key: "note") var note: String?
    @Field(key: "status") var status: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(reporterId: UUID, targetType: String, targetId: String, reason: String, note: String?) {
        self.reporterId = reporterId
        self.targetType = targetType
        self.targetId = targetId
        self.reason = reason
        self.note = note
        status = "open"
    }
}

/// Per-user social privacy. A user without a row gets the defaults, except
/// contact matching: that needs `email_hash`, which is only written once the
/// user has used the social API.
final class SocialSettingsRecord: Model, @unchecked Sendable {
    static let schema = "social_settings"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "search_visibility") var searchVisibility: String
    @Field(key: "discoverable_by_contacts") var discoverableByContacts: Bool
    @Field(key: "discoverable_by_x") var discoverableByX: Bool
    @Field(key: "show_return_percent") var showReturnPercent: Bool
    @Field(key: "show_streaks") var showStreaks: Bool
    @Field(key: "show_xp") var showXP: Bool
    @Field(key: "leaderboard_opt_in") var leaderboardOptIn: Bool
    /// HMAC of the normalized account email under the current contact pepper.
    @OptionalField(key: "email_hash") var emailHash: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(userId: UUID, settings: SocialPrivacySettingsDTO = .default) {
        self.userId = userId
        apply(settings)
    }

    func apply(_ settings: SocialPrivacySettingsDTO) {
        searchVisibility = settings.searchVisibility.rawValue
        discoverableByContacts = settings.discoverableByContacts
        discoverableByX = settings.discoverableByX
        showReturnPercent = settings.showReturnPercent
        showStreaks = settings.showStreaks
        showXP = settings.showXP
        leaderboardOptIn = settings.leaderboardOptIn
    }

    var dto: SocialPrivacySettingsDTO {
        SocialPrivacySettingsDTO(
            searchVisibility: SocialSearchVisibility(rawValue: searchVisibility) ?? .everyone,
            discoverableByContacts: discoverableByContacts,
            discoverableByX: discoverableByX,
            showReturnPercent: showReturnPercent,
            showStreaks: showStreaks,
            showXP: showXP,
            leaderboardOptIn: leaderboardOptIn
        )
    }
}

/// One reusable invite code per user.
final class SocialInvite: Model, @unchecked Sendable {
    static let schema = "social_invites"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "code") var code: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userId: UUID, code: String) {
        self.userId = userId
        self.code = code
    }
}
