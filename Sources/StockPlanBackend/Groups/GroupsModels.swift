import Fluent
import Foundation

/// Named `GroupRecord` rather than `Group` so it never collides with
/// `SwiftUI.Group` when the type name travels into shared code.
final class GroupRecord: Model, @unchecked Sendable {
    static let schema = "groups"

    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @Field(key: "description") var description: String
    @OptionalField(key: "icon_emoji") var iconEmoji: String?
    @Field(key: "topic") var topic: String
    @OptionalField(key: "ticker") var ticker: String?
    @Field(key: "visibility") var visibility: String
    /// Nil only between the owner's account deletion and the next read, which
    /// promotes someone (`GroupsService.ensureOwner`).
    @OptionalField(key: "owner_id") var ownerId: UUID?
    @Field(key: "member_count") var memberCount: Int
    @OptionalField(key: "last_message_at") var lastMessageAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(
        name: String,
        description: String,
        iconEmoji: String?,
        topic: String,
        ticker: String?,
        visibility: String,
        ownerId: UUID
    ) {
        self.name = name
        self.description = description
        self.iconEmoji = iconEmoji
        self.topic = topic
        self.ticker = ticker
        self.visibility = visibility
        self.ownerId = ownerId
        memberCount = 1
    }
}

final class GroupChannelRecord: Model, @unchecked Sendable {
    static let schema = "group_channels"

    @ID(key: .id) var id: UUID?
    @Field(key: "group_id") var groupId: UUID
    @Field(key: "name") var name: String
    @Field(key: "kind") var kind: String
    @OptionalField(key: "topic") var topic: String?
    @Field(key: "position") var position: Int
    /// Bumped inside each message insert; the newest message's `seq`.
    @Field(key: "last_seq") var lastSeq: Int64
    @OptionalField(key: "last_message_at") var lastMessageAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(groupId: UUID, name: String, topic: String?, position: Int) {
        self.groupId = groupId
        self.name = name
        kind = "text"
        self.topic = topic
        self.position = position
        lastSeq = 0
    }
}

final class GroupMemberRecord: Model, @unchecked Sendable {
    static let schema = "group_members"

    @ID(key: .id) var id: UUID?
    @Field(key: "group_id") var groupId: UUID
    @Field(key: "user_id") var userId: UUID
    @Field(key: "role") var role: String
    @Field(key: "push_enabled") var pushEnabled: Bool
    @Timestamp(key: "joined_at", on: .create) var joinedAt: Date?

    init() {}

    init(groupId: UUID, userId: UUID, role: String, pushEnabled: Bool) {
        self.groupId = groupId
        self.userId = userId
        self.role = role
        self.pushEnabled = pushEnabled
    }
}

final class GroupChannelRead: Model, @unchecked Sendable {
    static let schema = "group_channel_reads"

    @ID(key: .id) var id: UUID?
    @Field(key: "channel_id") var channelId: UUID
    @Field(key: "user_id") var userId: UUID
    @Field(key: "last_read_seq") var lastReadSeq: Int64
    @Field(key: "updated_at") var updatedAt: Date

    init() {}
}

/// A deleted message keeps its row and body (moderators read reported
/// messages after the author deletes them); `deleted_at` is a plain field so
/// listings still return the tombstone.
final class GroupMessageRecord: Model, @unchecked Sendable {
    static let schema = "group_messages"

    @ID(key: .id) var id: UUID?
    @Field(key: "channel_id") var channelId: UUID
    @Field(key: "group_id") var groupId: UUID
    @Field(key: "author_id") var authorId: UUID
    @Field(key: "seq") var seq: Int64
    @Field(key: "client_message_id") var clientMessageId: String
    @Field(key: "body") var body: String
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "deleted_at") var deletedAt: Date?
    @OptionalField(key: "deleted_by") var deletedBy: UUID?

    init() {}
}

/// Either a shareable link (`code`) or a direct invitation to one friend
/// (`invitee_id`); a database check keeps exactly one of them set.
final class GroupInviteRecord: Model, @unchecked Sendable {
    static let schema = "group_invites"

    @ID(key: .id) var id: UUID?
    @Field(key: "group_id") var groupId: UUID
    @OptionalField(key: "created_by") var createdBy: UUID?
    @OptionalField(key: "code") var code: String?
    @OptionalField(key: "invitee_id") var inviteeId: UUID?
    @OptionalField(key: "expires_at") var expiresAt: Date?
    @OptionalField(key: "max_uses") var maxUses: Int?
    @Field(key: "uses") var uses: Int
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    @OptionalField(key: "accepted_at") var acceptedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(groupId: UUID, createdBy: UUID, code: String?, inviteeId: UUID?, expiresAt: Date?, maxUses: Int?) {
        self.groupId = groupId
        self.createdBy = createdBy
        self.code = code
        self.inviteeId = inviteeId
        self.expiresAt = expiresAt
        self.maxUses = maxUses
        uses = 0
    }
}

final class GroupBanRecord: Model, @unchecked Sendable {
    static let schema = "group_bans"

    @ID(key: .id) var id: UUID?
    @Field(key: "group_id") var groupId: UUID
    @Field(key: "user_id") var userId: UUID
    @OptionalField(key: "banned_by") var bannedBy: UUID?
    @OptionalField(key: "reason") var reason: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(groupId: UUID, userId: UUID, bannedBy: UUID, reason: String?) {
        self.groupId = groupId
        self.userId = userId
        self.bannedBy = bannedBy
        self.reason = reason
    }
}
