import Fluent
import Foundation

/// One item in the friends' activity feed: an achievement a user unlocked.
/// `kind` is text (`achievement` today) so the feed can grow without a
/// migration. Deleting the unlock deletes the item.
final class SocialActivity: Model, @unchecked Sendable {
    static let schema = "social_activity"

    @ID(key: .id) var id: UUID?
    @Field(key: "actor_id") var actorId: UUID
    @Field(key: "kind") var kind: String
    @Field(key: "user_achievement_id") var userAchievementId: UUID
    @Field(key: "created_at") var createdAt: Date

    init() {}

    init(actorId: UUID, kind: String, userAchievementId: UUID, createdAt: Date = Date()) {
        self.actorId = actorId
        self.kind = kind
        self.userAchievementId = userAchievementId
        self.createdAt = createdAt
    }
}

/// A friend's congratulations on an activity item, at most one per friend.
final class SocialCongrats: Model, @unchecked Sendable {
    static let schema = "social_congrats"

    @ID(key: .id) var id: UUID?
    @Field(key: "activity_id") var activityId: UUID
    @Field(key: "from_user_id") var fromUserId: UUID
    @Field(key: "created_at") var createdAt: Date

    init() {}

    init(activityId: UUID, fromUserId: UUID, createdAt: Date = Date()) {
        self.activityId = activityId
        self.fromUserId = fromUserId
        self.createdAt = createdAt
    }
}

/// A new account that joined through someone's invite link. Credits the
/// inviter (`social.inviter`); an invitee is credited to one inviter, once.
final class SocialInviteRedemption: Model, @unchecked Sendable {
    static let schema = "social_invite_redemptions"

    @ID(key: .id) var id: UUID?
    @Field(key: "invite_id") var inviteId: UUID
    @Field(key: "inviter_id") var inviterId: UUID
    @Field(key: "invitee_id") var inviteeId: UUID
    @Field(key: "redeemed_at") var redeemedAt: Date

    init() {}

    init(inviteId: UUID, inviterId: UUID, inviteeId: UUID, redeemedAt: Date = Date()) {
        self.inviteId = inviteId
        self.inviterId = inviterId
        self.inviteeId = inviteeId
        self.redeemedAt = redeemedAt
    }
}
