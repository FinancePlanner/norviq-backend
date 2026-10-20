import Fluent
import FluentSQL
import Foundation
import StockPlanShared
import Vapor

/// Membership rules, read state and DTO mapping for Groups. A private group
/// answers 404 to anyone outside it, so its existence never leaks; a public
/// one shows non-members a preview and asks them to join before reading.
enum GroupsService {
    // MARK: - Lookup and access

    static func group(_ id: UUID, on db: any Database) async throws -> GroupRecord {
        guard let group = try await GroupRecord.find(id, on: db) else {
            throw notFound
        }
        return group
    }

    static var notFound: CodedAbort {
        CodedAbort(status: .notFound, code: "group_not_found", reason: "Group not found")
    }

    static func membership(groupId: UUID, userId: UUID, on db: any Database) async throws -> GroupMemberRecord? {
        try await GroupMemberRecord.query(on: db)
            .filter(\.$groupId == groupId)
            .filter(\.$userId == userId)
            .first()
    }

    /// The viewer's membership, or nil on a public group they can preview.
    /// Throws 404 for a private group they're not in; global admins see
    /// every group so reports can be reviewed in context.
    static func access(_ group: GroupRecord, viewer: CommunityViewer, on db: any Database) async throws -> GroupMemberRecord? {
        let member = try await membership(groupId: group.requireID(), userId: viewer.userId, on: db)
        if member == nil, group.visibility != GroupVisibility.public.rawValue, !viewer.isAdmin {
            throw notFound
        }
        return member
    }

    static func requireMember(_ group: GroupRecord, viewer: CommunityViewer, on db: any Database) async throws -> GroupMemberRecord {
        guard let member = try await access(group, viewer: viewer, on: db) else {
            throw CodedAbort(status: .forbidden, code: "group_membership_required", reason: "Join the group first.")
        }
        return member
    }

    static func requireManager(_ member: GroupMemberRecord) throws {
        guard role(member).canManage else {
            throw CodedAbort(status: .forbidden, code: "group_forbidden", reason: "Only the group's owner and admins can do that.")
        }
    }

    static func requireOwner(_ member: GroupMemberRecord) throws {
        guard role(member) == .owner else {
            throw CodedAbort(status: .forbidden, code: "group_forbidden", reason: "Only the group's owner can do that.")
        }
    }

    static func role(_ member: GroupMemberRecord) -> GroupRole {
        GroupRole(rawValue: member.role) ?? .member
    }

    /// Owner 3, admin 2, member 1. Moderation needs a strictly higher rank.
    static func rank(_ role: GroupRole) -> Int {
        switch role {
        case .owner: 3
        case .admin: 2
        case .member, .other: 1
        }
    }

    static func channel(_ id: UUID, on db: any Database) async throws -> (GroupChannelRecord, GroupRecord) {
        guard let channel = try await GroupChannelRecord.find(id, on: db),
              let group = try await GroupRecord.find(channel.groupId, on: db)
        else {
            throw CodedAbort(status: .notFound, code: "channel_not_found", reason: "Channel not found")
        }
        return (channel, group)
    }

    static func channels(groupIds: [UUID], on db: any Database) async throws -> [GroupChannelRecord] {
        guard !groupIds.isEmpty else { return [] }
        return try await GroupChannelRecord.query(on: db)
            .filter(\.$groupId ~~ groupIds)
            .sort(\.$position)
            .sort(\.$createdAt)
            .all()
    }

    // MARK: - Membership changes

    /// Adds `userId` and marks every channel read up to now, so joining never
    /// shows the whole history as unread. Run inside a transaction.
    static func addMember(
        _ group: GroupRecord,
        userId: UUID,
        role: GroupRole,
        pushEnabled: Bool,
        on db: any Database
    ) async throws {
        let groupId = try group.requireID()
        let banned = try await GroupBanRecord.query(on: db)
            .filter(\.$groupId == groupId)
            .filter(\.$userId == userId)
            .first() != nil
        guard !banned else {
            throw CodedAbort(status: .forbidden, code: "group_banned", reason: "You can't join this group.")
        }
        let members = try await GroupMemberRecord.query(on: db).filter(\.$groupId == groupId).count()
        guard members < GroupsValidation.maxMembers else {
            throw CodedAbort(status: .conflict, code: "group_full", reason: "This group is full.")
        }
        let joined = try await GroupMemberRecord.query(on: db).filter(\.$userId == userId).count()
        guard joined < GroupsValidation.maxGroupsJoined else {
            throw CodedAbort(
                status: .conflict,
                code: "group_join_limit",
                reason: "You can be in up to \(GroupsValidation.maxGroupsJoined) groups. Leave one to join another."
            )
        }
        try await GroupMemberRecord(groupId: groupId, userId: userId, role: role.rawValue, pushEnabled: pushEnabled)
            .create(on: db)
        let now = Date()
        try await sql(db).raw("""
        INSERT INTO group_channel_reads (id, channel_id, user_id, last_read_seq, updated_at)
        SELECT gen_random_uuid(), c.id, \(bind: userId), c.last_seq, \(bind: now)
        FROM group_channels c WHERE c.group_id = \(bind: groupId) AND c.deleted_at IS NULL
        ON CONFLICT (channel_id, user_id) DO UPDATE SET last_read_seq = EXCLUDED.last_read_seq, updated_at = EXCLUDED.updated_at
        """).run()
        try await refreshMemberCount(groupId, on: db)
    }

    static func removeMember(groupId: UUID, userId: UUID, on db: any Database) async throws {
        try await GroupMemberRecord.query(on: db)
            .filter(\.$groupId == groupId)
            .filter(\.$userId == userId)
            .delete()
        try await sql(db).raw("""
        DELETE FROM group_channel_reads
        WHERE user_id = \(bind: userId)
          AND channel_id IN (SELECT id FROM group_channels WHERE group_id = \(bind: groupId))
        """).run()
        try await refreshMemberCount(groupId, on: db)
    }

    /// Recounted rather than incremented, so rows removed by an account
    /// deletion cascade heal on the next change.
    static func refreshMemberCount(_ groupId: UUID, on db: any Database) async throws {
        try await sql(db).raw("""
        UPDATE groups SET member_count = (SELECT COUNT(*) FROM group_members WHERE group_id = \(bind: groupId))
        WHERE id = \(bind: groupId)
        """).run()
    }

    /// When the owner's account is deleted the group keeps going: the oldest
    /// admin takes over, else the oldest member; an empty group is deleted.
    static func ensureOwner(_ group: GroupRecord, on db: any Database) async throws {
        guard group.ownerId == nil else { return }
        let groupId = try group.requireID()
        let members = try await GroupMemberRecord.query(on: db)
            .filter(\.$groupId == groupId)
            .sort(\.$joinedAt)
            .all()
        guard let heir = members.first(where: { $0.role == GroupRole.admin.rawValue }) ?? members.first else {
            try await group.delete(on: db)
            throw notFound
        }
        heir.role = GroupRole.owner.rawValue
        try await heir.save(on: db)
        group.ownerId = heir.userId
        try await group.save(on: db)
    }

    // MARK: - Read state

    struct ReadState {
        let lastReadSeq: Int64
        let unread: Int
    }

    /// Read marker and unread count per channel. Your own messages, deleted
    /// ones and those from people hidden from you never count.
    static func readState(
        channelIds: [UUID],
        userId: UUID,
        hidden: Set<UUID>,
        on db: any Database
    ) async throws -> [UUID: ReadState] {
        guard !channelIds.isEmpty else { return [:] }
        let rows = try await sql(db).raw("""
        SELECT c.id AS channel_id,
               COALESCE(r.last_read_seq, 0) AS last_read,
               (SELECT COUNT(*) FROM group_messages m
                WHERE m.channel_id = c.id
                  AND m.seq > COALESCE(r.last_read_seq, 0)
                  AND m.deleted_at IS NULL
                  AND m.author_id <> \(bind: userId)
                  AND NOT (m.author_id = ANY(\(bind: Array(hidden))))) AS unread
        FROM group_channels c
        LEFT JOIN group_channel_reads r ON r.channel_id = c.id AND r.user_id = \(bind: userId)
        WHERE c.id = ANY(\(bind: channelIds))
        """).all()
        var result: [UUID: ReadState] = [:]
        for row in rows {
            let id = try row.decode(column: "channel_id", as: UUID.self)
            result[id] = try ReadState(
                lastReadSeq: row.decode(column: "last_read", as: Int64.self),
                unread: Int(row.decode(column: "unread", as: Int64.self))
            )
        }
        return result
    }

    /// Unread messages across every group `userId` belongs to.
    static func totalUnread(for userId: UUID, hidden: Set<UUID>, on db: any Database) async throws -> Int {
        let row = try await sql(db).raw("""
        SELECT COUNT(*) AS unread
        FROM group_members gm
        JOIN groups g ON g.id = gm.group_id AND g.deleted_at IS NULL
        JOIN group_channels c ON c.group_id = gm.group_id AND c.deleted_at IS NULL
        LEFT JOIN group_channel_reads r ON r.channel_id = c.id AND r.user_id = gm.user_id
        JOIN group_messages m ON m.channel_id = c.id AND m.seq > COALESCE(r.last_read_seq, 0)
        WHERE gm.user_id = \(bind: userId)
          AND m.deleted_at IS NULL
          AND m.author_id <> \(bind: userId)
          AND NOT (m.author_id = ANY(\(bind: Array(hidden))))
        """).first()
        return try Int(row?.decode(column: "unread", as: Int64.self) ?? 0)
    }

    static func pendingInvitationCount(for userId: UUID, hidden: Set<UUID>, on db: any Database) async throws -> Int {
        try await pendingInvitations(for: userId, hidden: hidden, on: db).count
    }

    static func pendingInvitations(for userId: UUID, hidden: Set<UUID>, on db: any Database) async throws -> [GroupInviteRecord] {
        let rows = try await GroupInviteRecord.query(on: db)
            .filter(\.$inviteeId == userId)
            .filter(\.$acceptedAt == nil)
            .filter(\.$revokedAt == nil)
            .sort(\.$createdAt, .descending)
            .all()
        let live = try await GroupRecord.query(on: db).filter(\.$id ~~ rows.map(\.groupId)).all().compactMap(\.id)
        return rows.filter { invite in
            live.contains(invite.groupId) && !(invite.createdBy.map(hidden.contains) ?? false)
        }
    }

    // MARK: - Mapping

    static func permissions(_ member: GroupMemberRecord?, viewer: CommunityViewer) -> GroupPermissions {
        guard let member else {
            return viewer.isAdmin
                ? GroupPermissions(canPost: false, canInvite: false, canEdit: false, canManageChannels: false, canModerate: true, canDelete: true)
                : .none
        }
        let role = role(member)
        return GroupPermissions(
            canPost: !viewer.isMuted,
            canInvite: true,
            canEdit: role.canManage,
            canManageChannels: role.canManage,
            canModerate: role.canManage || viewer.isAdmin,
            canDelete: role == .owner || viewer.isAdmin
        )
    }

    static func membershipDTO(_ member: GroupMemberRecord) -> GroupMembership {
        GroupMembership(role: role(member), pushEnabled: member.pushEnabled, joinedAt: member.joinedAt ?? Date())
    }

    static func channelDTO(_ channel: GroupChannelRecord, read: ReadState?) throws -> GroupChannel {
        try GroupChannel(
            id: channel.requireID(),
            groupId: channel.groupId,
            name: channel.name,
            kind: GroupChannelKind(rawValue: channel.kind) ?? .other,
            topic: channel.topic,
            position: channel.position,
            lastSeq: channel.lastSeq,
            lastMessageAt: channel.lastMessageAt,
            lastReadSeq: read?.lastReadSeq ?? 0,
            unreadCount: read?.unread ?? 0
        )
    }

    static func messageDTO(_ message: GroupMessageRecord, usernames: [UUID: String]) throws -> GroupMessage {
        let deleted = message.deletedAt != nil
        return try GroupMessage(
            id: message.requireID(),
            groupId: message.groupId,
            channelId: message.channelId,
            seq: message.seq,
            clientMessageId: message.clientMessageId,
            authorId: message.authorId,
            authorUsername: usernames[message.authorId],
            body: deleted ? nil : message.body,
            isDeleted: deleted,
            createdAt: message.createdAt
        )
    }

    /// Summaries as `viewer` sees them, in the order given.
    static func summaries(_ groups: [GroupRecord], viewerId: UUID, hidden: Set<UUID>, on db: any Database) async throws -> [GroupSummary] {
        let groupIds = try groups.map { try $0.requireID() }
        guard !groupIds.isEmpty else { return [] }

        let memberships = try await GroupMemberRecord.query(on: db)
            .filter(\.$groupId ~~ groupIds)
            .filter(\.$userId == viewerId)
            .all()
        let membershipByGroup = Dictionary(memberships.map { ($0.groupId, $0) }, uniquingKeysWith: { a, _ in a })

        let channels = try await channels(groupIds: groupIds, on: db)
        let defaultChannel = Dictionary(channels.compactMap { c in c.id.map { (c.groupId, $0) } }, uniquingKeysWith: { a, _ in a })
        let memberChannelIds = channels.filter { membershipByGroup[$0.groupId] != nil }.compactMap(\.id)
        let reads = try await readState(channelIds: memberChannelIds, userId: viewerId, hidden: hidden, on: db)
        var unreadByGroup: [UUID: Int] = [:]
        for channel in channels {
            if let id = channel.id, let read = reads[id] {
                unreadByGroup[channel.groupId, default: 0] += read.unread
            }
        }

        let latest = try await sql(db).raw("""
        SELECT DISTINCT ON (m.group_id) m.group_id, m.author_id, m.body, m.deleted_at, m.created_at
        FROM group_messages m
        JOIN group_channels c ON c.id = m.channel_id AND c.deleted_at IS NULL
        WHERE m.group_id = ANY(\(bind: groupIds))
          AND NOT (m.author_id = ANY(\(bind: Array(hidden))))
        ORDER BY m.group_id, m.created_at DESC
        """).all()
        var previews: [UUID: (author: UUID, body: String, deleted: Bool, at: Date)] = [:]
        for row in latest {
            let groupId = try row.decode(column: "group_id", as: UUID.self)
            previews[groupId] = try (
                row.decode(column: "author_id", as: UUID.self),
                row.decode(column: "body", as: String.self),
                row.decode(column: "deleted_at", as: Date?.self) != nil,
                row.decode(column: "created_at", as: Date.self)
            )
        }
        let names = try await BoardsService.usernames(for: previews.values.map(\.author), on: db)

        return try groups.map { group in
            let id = try group.requireID()
            let member = membershipByGroup[id]
            let preview = previews[id].map { preview in
                GroupMessagePreview(
                    authorUsername: names[preview.author],
                    excerpt: preview.deleted ? nil : String(preview.body.prefix(140)),
                    createdAt: preview.at
                )
            }
            return GroupSummary(
                id: id,
                name: group.name,
                description: group.description,
                iconEmoji: group.iconEmoji,
                topic: GroupTopic(rawValue: group.topic) ?? .other,
                ticker: group.ticker,
                visibility: GroupVisibility(rawValue: group.visibility) ?? .private,
                memberCount: group.memberCount,
                defaultChannelId: defaultChannel[id],
                lastMessageAt: group.lastMessageAt,
                lastMessage: member == nil ? nil : preview,
                unreadCount: member == nil ? 0 : unreadByGroup[id] ?? 0,
                membership: member.map(membershipDTO),
                createdAt: group.createdAt ?? Date()
            )
        }
    }

    static func detail(_ stale: GroupRecord, viewer: CommunityViewer, on db: any Database) async throws -> GroupDetail {
        // Reloaded so counts reflect a join or leave made in the same request.
        let group = try await GroupsService.group(stale.requireID(), on: db)
        try await ensureOwner(group, on: db)
        let member = try await access(group, viewer: viewer, on: db)
        let hidden = try await SocialService.blockedEitherWay(for: viewer.userId, on: db)
        let summary = try await summaries([group], viewerId: viewer.userId, hidden: hidden, on: db)[0]
        var channelDTOs: [GroupChannel] = []
        if member != nil || viewer.isAdmin {
            let records = try await channels(groupIds: [group.requireID()], on: db)
            let reads: [UUID: ReadState] = member == nil
                ? [:]
                : try await readState(channelIds: records.compactMap(\.id), userId: viewer.userId, hidden: hidden, on: db)
            channelDTOs = try records.map { record in try channelDTO(record, read: record.id.flatMap { reads[$0] }) }
        }
        var owner: String?
        if let ownerId = group.ownerId {
            owner = try await User.find(ownerId, on: db)?.username
        }
        return GroupDetail(
            group: summary,
            channels: channelDTOs,
            permissions: permissions(member, viewer: viewer),
            ownerUsername: owner
        )
    }

    static func inviteURL(code: String) -> String {
        let base = SocialConfiguration.fromEnvironment().inviteBaseURL
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return "\(trimmed)/g/\(code)"
    }

    static func inviteLinkDTO(_ invite: GroupInviteRecord, usernames: [UUID: String]) throws -> GroupInviteLink {
        let code = invite.code ?? ""
        return try GroupInviteLink(
            id: invite.requireID(),
            groupId: invite.groupId,
            code: code,
            url: inviteURL(code: code),
            expiresAt: invite.expiresAt,
            maxUses: invite.maxUses,
            uses: invite.uses,
            createdByUsername: invite.createdBy.flatMap { usernames[$0] },
            createdAt: invite.createdAt ?? Date()
        )
    }

    static func sql(_ db: any Database) throws -> any SQLDatabase {
        try BoardsController.sql(db)
    }
}

/// Short, unambiguous invite codes, shared by friend and group invites.
/// Collisions over 57^10 are not a practical concern; the unique index is the
/// backstop, and a retry picks a fresh code.
enum InviteCode {
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")

    static func generate(length: Int = 10) -> String {
        String((0 ..< length).map { _ in alphabet.randomElement() ?? "x" })
    }

    static func isWellFormed(_ code: String) -> Bool {
        (4 ... 64).contains(code.count) && code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
