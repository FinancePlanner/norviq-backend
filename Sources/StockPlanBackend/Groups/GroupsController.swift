import Fluent
import FluentSQL
import Foundation
import StockPlanShared
import Vapor

/// `/v1/groups`, `/v1/group-channels` (management) and `/v1/group-invites`:
/// Discord-style groups with text channels. First-party sessions only, off
/// unless `GROUPS_ENABLED`, and behind the same community gate as Boards, so a
/// global ban or mute bites here too. Messages live in
/// `GroupMessagesController`.
struct GroupsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let base = routes.grouped(
            ScopedBearerAuthenticator(),
            SessionToken.guardMiddleware(),
            FirstPartyOnlyMiddleware(),
            GroupsEnabledMiddleware(),
            CommunityAccessMiddleware()
        )

        let groups = base.grouped("groups")
        groups.get(use: myGroups)
        // The daily cap is enforced in the handler against the database; this
        // only stops a burst.
        groups.grouped(RateLimitMiddleware(limit: 10, interval: 3600, keyPrefix: "ratelimit:group-create"))
            .post(use: createGroup)
        groups.grouped(RateLimitMiddleware(limit: 60, interval: 60, keyPrefix: "ratelimit:group-discover"))
            .get("discover", use: discover)
        groups.get("unread-count", use: unreadCount)
        groups.get("invitations", use: invitations)
        groups.post("invitations", ":inviteId", "accept", use: acceptInvitation)
        groups.post("invitations", ":inviteId", "decline", use: declineInvitation)

        groups.get(":groupId", use: getGroup)
        groups.grouped(RateLimitMiddleware(limit: 30, interval: 3600, keyPrefix: "ratelimit:group-edit"))
            .patch(":groupId", use: updateGroup)
        groups.delete(":groupId", use: deleteGroup)
        groups.grouped(RateLimitMiddleware(limit: 30, interval: 3600, keyPrefix: "ratelimit:group-join"))
            .post(":groupId", "join", use: joinGroup)
        groups.post(":groupId", "leave", use: leaveGroup)
        groups.put(":groupId", "notifications", use: updateNotifications)

        groups.get(":groupId", "members", use: members)
        groups.patch(":groupId", "members", ":userId", use: updateMember)
        groups.delete(":groupId", "members", ":userId", use: kickMember)
        groups.post(":groupId", "transfer", use: transferOwnership)
        groups.get(":groupId", "bans", use: bans)
        groups.post(":groupId", "bans", use: banMember)
        groups.delete(":groupId", "bans", ":userId", use: unbanMember)

        groups.grouped(RateLimitMiddleware(limit: 30, interval: 3600, keyPrefix: "ratelimit:group-channel"))
            .post(":groupId", "channels", use: createChannel)
        let channels = base.grouped("group-channels")
        channels.patch(":channelId", use: updateChannel)
        channels.delete(":channelId", use: deleteChannel)

        groups.grouped(RateLimitMiddleware(limit: 20, interval: 3600, keyPrefix: "ratelimit:group-invite"))
            .post(":groupId", "invites", use: createInviteLink)
        groups.get(":groupId", "invites", use: inviteLinks)
        groups.grouped(RateLimitMiddleware(limit: 20, interval: 3600, keyPrefix: "ratelimit:group-invitation"))
            .post(":groupId", "invitations", use: inviteFriends)

        let invites = base.grouped("group-invites")
        invites.grouped(RateLimitMiddleware(limit: 30, interval: 60, keyPrefix: "ratelimit:group-invite-preview"))
            .get(":code", use: previewInvite)
        invites.grouped(RateLimitMiddleware(limit: 30, interval: 3600, keyPrefix: "ratelimit:group-invite-redeem"))
            .post(":code", "redeem", use: redeemInvite)
        invites.delete(":inviteId", use: revokeInvite)
    }

    // MARK: - Groups

    @Sendable
    func myGroups(req: Request) async throws -> GroupListResponse {
        let viewer = try req.communityViewer
        let memberships = try await GroupMemberRecord.query(on: req.db).filter(\.$userId == viewer.userId).all()
        let groups = try await GroupRecord.query(on: req.db)
            .filter(\.$id ~~ memberships.map(\.groupId))
            .all()
            .sorted { ($0.lastMessageAt ?? $0.createdAt ?? .distantPast) > ($1.lastMessageAt ?? $1.createdAt ?? .distantPast) }
        let hidden = try await SocialService.blockedEitherWay(for: viewer.userId, on: req.db)
        return try await GroupListResponse(
            items: GroupsService.summaries(groups, viewerId: viewer.userId, hidden: hidden, on: req.db),
            pendingInvitationCount: GroupsService.pendingInvitationCount(for: viewer.userId, hidden: hidden, on: req.db)
        )
    }

    @Sendable
    func createGroup(req: Request) async throws -> GroupDetail {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let config = GroupsConfiguration.fromEnvironment()
        let body = try req.content.decode(CreateGroupRequest.self)
        guard body.topic != .other else {
            throw Abort(.badRequest, reason: "Pick a topic for the group.")
        }
        let name = try GroupsValidation.groupName(body.name)
        let description = try GroupsValidation.groupDescription(body.description)
        let icon = try GroupsValidation.iconEmoji(body.iconEmoji)
        let ticker = try GroupsValidation.ticker(body.ticker, topic: body.topic)
        if body.visibility == .public, !config.publicDirectory {
            throw Abort(.badRequest, reason: "Public groups aren't available right now.")
        }

        if !viewer.isAdmin {
            // Deleted groups still count, or deleting would refill the quota.
            let recent = try await GroupRecord.query(on: req.db)
                .withDeleted()
                .filter(\.$ownerId == viewer.userId)
                .filter(\.$createdAt > Date().addingTimeInterval(-86400))
                .count()
            guard recent < GroupsValidation.maxGroupsCreatedPerDay else {
                throw CodedAbort(
                    status: .tooManyRequests,
                    code: "group_create_limit",
                    reason: "You can create up to \(GroupsValidation.maxGroupsCreatedPerDay) groups a day."
                )
            }
            let owned = try await GroupRecord.query(on: req.db).filter(\.$ownerId == viewer.userId).count()
            guard owned < GroupsValidation.maxGroupsOwned else {
                throw CodedAbort(
                    status: .conflict,
                    code: "group_owned_limit",
                    reason: "You can own up to \(GroupsValidation.maxGroupsOwned) groups."
                )
            }
        }

        let group = GroupRecord(
            name: name,
            description: description,
            iconEmoji: icon,
            topic: body.topic.rawValue,
            ticker: ticker,
            visibility: body.visibility.rawValue,
            ownerId: viewer.userId
        )
        try await req.db.transaction { tx in
            try await group.create(on: tx)
            try await GroupChannelRecord(
                groupId: group.requireID(),
                name: GroupsValidation.defaultChannelName,
                topic: nil,
                position: 0
            ).create(on: tx)
            try await GroupsService.addMember(group, userId: viewer.userId, role: .owner, pushEnabled: true, on: tx)
        }
        req.scheduleAchievementCheck(for: viewer.userId)
        req.logger.info("groups.created visibility=\(body.visibility.rawValue) topic=\(body.topic.rawValue)")
        return try await GroupsService.detail(GroupsService.group(group.requireID(), on: req.db), viewer: viewer, on: req.db)
    }

    /// Public groups, most members first. `ticker` matches exactly; `tickers`
    /// (comma-separated, up to 10) backs "suggested for you" from the client's
    /// holdings, which the server never infers; `q` searches names.
    @Sendable
    func discover(req: Request) async throws -> GroupDirectoryPage {
        let viewer = try req.communityViewer
        guard GroupsConfiguration.fromEnvironment().publicDirectory else {
            throw Abort(.notFound)
        }
        let pageSize = 25
        let offset = max(0, Int(req.query[String.self, at: "cursor"] ?? "") ?? 0)
        var query = GroupRecord.query(on: req.db).filter(\.$visibility == GroupVisibility.public.rawValue)

        var tickers: [String] = []
        if let ticker = try GroupsValidation.ticker(req.query[String.self, at: "ticker"], topic: .stock) {
            tickers.append(ticker)
        }
        if let list = req.query[String.self, at: "tickers"] {
            for raw in list.split(separator: ",").prefix(10) {
                if let ticker = try? GroupsValidation.ticker(String(raw), topic: .stock) {
                    tickers.append(ticker)
                }
            }
        }
        if !tickers.isEmpty {
            query = query.filter(\.$ticker ~~ tickers.map { Optional($0) })
        }
        if let q = req.query[String.self, at: "q"]?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            let escaped = String(q.prefix(50))
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            query = query.filter(\.$name, .custom("ILIKE"), "%\(escaped)%")
        }
        let hidden = try await SocialService.blockedEitherWay(for: viewer.userId, on: req.db)
        let rows = try await query
            .sort(\.$memberCount, .descending)
            .sort(\.$lastMessageAt, .descending)
            .sort(\.$id)
            .range(offset ..< offset + pageSize + 1)
            .all()
        // Groups owned by someone hidden from the viewer drop out after paging,
        // so a page can come back a little short; the cursor stays correct.
        let page = rows.prefix(pageSize).filter { group in group.ownerId.map { !hidden.contains($0) } ?? true }
        return try await GroupDirectoryPage(
            items: GroupsService.summaries(page, viewerId: viewer.userId, hidden: hidden, on: req.db),
            nextCursor: rows.count > pageSize ? String(offset + pageSize) : nil
        )
    }

    @Sendable
    func unreadCount(req: Request) async throws -> GroupUnreadCount {
        let viewer = try req.communityViewer
        let hidden = try await SocialService.blockedEitherWay(for: viewer.userId, on: req.db)
        return try await GroupUnreadCount(
            total: GroupsService.totalUnread(for: viewer.userId, hidden: hidden, on: req.db),
            pendingInvitationCount: GroupsService.pendingInvitationCount(for: viewer.userId, hidden: hidden, on: req.db)
        )
    }

    @Sendable
    func getGroup(req: Request) async throws -> GroupDetail {
        let viewer = try req.communityViewer
        let group = try await GroupsService.group(Self.uuid("groupId", on: req), on: req.db)
        return try await GroupsService.detail(group, viewer: viewer, on: req.db)
    }

    @Sendable
    func updateGroup(req: Request) async throws -> GroupDetail {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let group = try await GroupsService.group(Self.uuid("groupId", on: req), on: req.db)
        let member = try await GroupsService.requireMember(group, viewer: viewer, on: req.db)
        try GroupsService.requireManager(member)
        let body = try req.content.decode(UpdateGroupRequest.self)

        if let name = body.name {
            group.name = try GroupsValidation.groupName(name)
        }
        if let description = body.description {
            group.description = try GroupsValidation.groupDescription(description)
        }
        if let icon = body.iconEmoji {
            group.iconEmoji = try GroupsValidation.iconEmoji(icon)
        }
        let topic = body.topic ?? GroupTopic(rawValue: group.topic) ?? .custom
        guard topic != .other else {
            throw Abort(.badRequest, reason: "Pick a topic for the group.")
        }
        group.topic = topic.rawValue
        if let ticker = body.ticker {
            group.ticker = try GroupsValidation.ticker(ticker, topic: topic)
        } else if !topic.allowsTicker {
            group.ticker = nil
        }
        if let visibility = body.visibility {
            if visibility == .public, !GroupsConfiguration.fromEnvironment().publicDirectory {
                throw Abort(.badRequest, reason: "Public groups aren't available right now.")
            }
            group.visibility = visibility.rawValue
        }
        try await group.save(on: req.db)
        try await announce(.groupUpdated, group.requireID(), on: req)
        return try await GroupsService.detail(group, viewer: viewer, on: req.db)
    }

    /// Soft delete; the owner or a global admin.
    @Sendable
    func deleteGroup(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        let group = try await GroupsService.group(Self.uuid("groupId", on: req), on: req.db)
        if !viewer.isAdmin {
            try await GroupsService.requireOwner(GroupsService.requireMember(group, viewer: viewer, on: req.db))
        }
        let memberIds = try await GroupMemberRecord.query(on: req.db).filter(\.$groupId == group.requireID()).all().map(\.userId)
        try await group.delete(on: req.db)
        try await GroupsRealtime.publish(
            GroupRealtimeEvent(type: .membershipRemoved, groupId: group.requireID(), reason: .deleted), to: Set(memberIds), on: req
        )
        return .noContent
    }

    /// Public groups only. Push starts off, as in a big Discord server; the
    /// member turns it on per group.
    @Sendable
    func joinGroup(req: Request) async throws -> GroupDetail {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let group = try await GroupsService.group(Self.uuid("groupId", on: req), on: req.db)
        guard group.visibility == GroupVisibility.public.rawValue,
              GroupsConfiguration.fromEnvironment().publicDirectory
        else {
            throw GroupsService.notFound
        }
        if let ownerId = group.ownerId, try await SocialService.isBlockedEitherWay(viewer.userId, ownerId, on: req.db) {
            throw GroupsService.notFound
        }
        if try await GroupsService.membership(groupId: group.requireID(), userId: viewer.userId, on: req.db) == nil {
            try await req.db.transaction { tx in
                try await GroupsService.addMember(group, userId: viewer.userId, role: .member, pushEnabled: false, on: tx)
            }
            req.scheduleAchievementCheck(for: viewer.userId)
        }
        try await announce(.groupUpdated, group.requireID(), on: req)
        return try await GroupsService.detail(group, viewer: viewer, on: req.db)
    }

    /// The owner must hand the group over first, unless they're the last one
    /// in it, in which case leaving deletes it.
    @Sendable
    func leaveGroup(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        let group = try await GroupsService.group(Self.uuid("groupId", on: req), on: req.db)
        let groupId = try group.requireID()
        guard let member = try await GroupsService.membership(groupId: groupId, userId: viewer.userId, on: req.db) else {
            return .noContent
        }
        if GroupsService.role(member) == .owner {
            let others = try await GroupMemberRecord.query(on: req.db)
                .filter(\.$groupId == groupId)
                .filter(\.$userId != viewer.userId)
                .count()
            guard others == 0 else {
                throw CodedAbort(
                    status: .conflict,
                    code: "owner_must_transfer",
                    reason: "Make someone else the owner before you leave."
                )
            }
            try await group.delete(on: req.db)
            await removed(viewer.userId, from: groupId, reason: .deleted, on: req)
            return .noContent
        }
        try await req.db.transaction { tx in
            try await GroupsService.removeMember(groupId: groupId, userId: viewer.userId, on: tx)
        }
        await removed(viewer.userId, from: groupId, reason: .left, on: req)
        await announce(.groupUpdated, groupId, on: req)
        return .noContent
    }

    @Sendable
    func updateNotifications(req: Request) async throws -> GroupMembership {
        let viewer = try req.communityViewer
        let group = try await GroupsService.group(Self.uuid("groupId", on: req), on: req.db)
        let member = try await GroupsService.requireMember(group, viewer: viewer, on: req.db)
        member.pushEnabled = try req.content.decode(GroupNotificationSettingsRequest.self).pushEnabled
        try await member.save(on: req.db)
        return GroupsService.membershipDTO(member)
    }

    // MARK: - Members

    @Sendable
    func members(req: Request) async throws -> GroupMemberPage {
        let viewer = try req.communityViewer
        let group = try await GroupsService.group(Self.uuid("groupId", on: req), on: req.db)
        if !viewer.isAdmin {
            _ = try await GroupsService.requireMember(group, viewer: viewer, on: req.db)
        }
        let pageSize = 100
        let offset = max(0, Int(req.query[String.self, at: "cursor"] ?? "") ?? 0)
        let hidden = try await SocialService.blockedEitherWay(for: viewer.userId, on: req.db)
        let rows = try await GroupMemberRecord.query(on: req.db)
            .filter(\.$groupId == group.requireID())
            .all()
            .filter { !hidden.contains($0.userId) }
            .sorted { lhs, rhs in
                let (l, r) = (GroupsService.rank(GroupsService.role(lhs)), GroupsService.rank(GroupsService.role(rhs)))
                return l != r ? l > r : (lhs.joinedAt ?? .distantPast) < (rhs.joinedAt ?? .distantPast)
            }
        let page = Array(rows.dropFirst(offset).prefix(pageSize))
        let names = try await BoardsService.usernames(for: page.map(\.userId), on: req.db)
        return GroupMemberPage(
            items: page.map { member in
                GroupMember(
                    userId: member.userId,
                    username: names[member.userId],
                    displayName: nil,
                    role: GroupsService.role(member),
                    joinedAt: member.joinedAt ?? Date()
                )
            },
            nextCursor: rows.count > offset + pageSize ? String(offset + pageSize) : nil
        )
    }

    /// Owner only: make someone an admin or a member again.
    @Sendable
    func updateMember(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        let group = try await GroupsService.group(Self.uuid("groupId", on: req), on: req.db)
        try await GroupsService.requireOwner(GroupsService.requireMember(group, viewer: viewer, on: req.db))
        let role = try req.content.decode(UpdateGroupMemberRequest.self).role
        guard role == .admin || role == .member else {
            throw Abort(.badRequest, reason: "A member can be made an admin or a member.")
        }
        let target = try await requireTarget(group, req: req)
        guard GroupsService.role(target) != .owner else {
            throw Abort(.badRequest, reason: "Transfer ownership instead.")
        }
        target.role = role.rawValue
        try await target.save(on: req.db)
        try await announce(.groupUpdated, group.requireID(), on: req)
        return .noContent
    }

    @Sendable
    func kickMember(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        let group = try await GroupsService.group(Self.uuid("groupId", on: req), on: req.db)
        let target = try await requireTarget(group, req: req)
        try await requireOutranks(group, target: target, viewer: viewer, on: req.db)
        try await req.db.transaction { tx in
            try await GroupsService.removeMember(groupId: target.groupId, userId: target.userId, on: tx)
        }
        await removed(target.userId, from: target.groupId, reason: .kicked, on: req)
        await announce(.groupUpdated, target.groupId, on: req)
        return .noContent
    }

    @Sendable
    func transferOwnership(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        let group = try await GroupsService.group(Self.uuid("groupId", on: req), on: req.db)
        let owner = try await GroupsService.requireMember(group, viewer: viewer, on: req.db)
        try GroupsService.requireOwner(owner)
        let userId = try req.content.decode(TransferGroupOwnershipRequest.self).userId
        guard userId != viewer.userId,
              let heir = try await GroupsService.membership(groupId: group.requireID(), userId: userId, on: req.db)
        else {
            throw Abort(.badRequest, reason: "Pick another member of the group.")
        }
        try await req.db.transaction { tx in
            heir.role = GroupRole.owner.rawValue
            try await heir.save(on: tx)
            owner.role = GroupRole.admin.rawValue
            try await owner.save(on: tx)
            group.ownerId = userId
            try await group.save(on: tx)
        }
        try await announce(.groupUpdated, group.requireID(), on: req)
        return .noContent
    }

    @Sendable
    func bans(req: Request) async throws -> GroupMemberPage {
        let viewer = try req.communityViewer
        let group = try await GroupsService.group(Self.uuid("groupId", on: req), on: req.db)
        if !viewer.isAdmin {
            try await GroupsService.requireManager(GroupsService.requireMember(group, viewer: viewer, on: req.db))
        }
        let rows = try await GroupBanRecord.query(on: req.db)
            .filter(\.$groupId == group.requireID())
            .sort(\.$createdAt, .descending)
            .limit(500)
            .all()
        let names = try await BoardsService.usernames(for: rows.map(\.userId), on: req.db)
        return GroupMemberPage(
            items: rows.map { ban in
                GroupMember(userId: ban.userId, username: names[ban.userId], displayName: nil, role: .member, joinedAt: ban.createdAt ?? Date())
            },
            nextCursor: nil
        )
    }

    /// Removes the user and stops them rejoining by link, invitation or the
    /// directory. Banning someone who already left is allowed.
    @Sendable
    func banMember(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        let group = try await GroupsService.group(Self.uuid("groupId", on: req), on: req.db)
        let groupId = try group.requireID()
        let body = try req.content.decode(GroupBanRequest.self)
        guard body.userId != viewer.userId else {
            throw Abort(.badRequest, reason: "You can't ban yourself.")
        }
        if let target = try await GroupsService.membership(groupId: groupId, userId: body.userId, on: req.db) {
            try await requireOutranks(group, target: target, viewer: viewer, on: req.db)
        } else if !viewer.isAdmin {
            try await GroupsService.requireManager(GroupsService.requireMember(group, viewer: viewer, on: req.db))
        }
        let reason = body.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await req.db.transaction { tx in
            try await GroupsService.removeMember(groupId: groupId, userId: body.userId, on: tx)
            let existing = try await GroupBanRecord.query(on: tx)
                .filter(\.$groupId == groupId)
                .filter(\.$userId == body.userId)
                .first()
            if existing == nil {
                try await GroupBanRecord(
                    groupId: groupId,
                    userId: body.userId,
                    bannedBy: viewer.userId,
                    reason: (reason?.isEmpty ?? true) ? nil : reason.map { String($0.prefix(300)) }
                ).create(on: tx)
            }
            // Pending invitations to the banned user die with the ban.
            try await GroupInviteRecord.query(on: tx)
                .filter(\.$groupId == groupId)
                .filter(\.$inviteeId == body.userId)
                .filter(\.$acceptedAt == nil)
                .set(\.$revokedAt, to: Date())
                .update()
        }
        await removed(body.userId, from: groupId, reason: .banned, on: req)
        await announce(.groupUpdated, groupId, on: req)
        return .noContent
    }

    @Sendable
    func unbanMember(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        let group = try await GroupsService.group(Self.uuid("groupId", on: req), on: req.db)
        if !viewer.isAdmin {
            try await GroupsService.requireManager(GroupsService.requireMember(group, viewer: viewer, on: req.db))
        }
        try await GroupBanRecord.query(on: req.db)
            .filter(\.$groupId == group.requireID())
            .filter(\.$userId == Self.uuid("userId", on: req))
            .delete()
        return .noContent
    }

    // MARK: - Channels

    @Sendable
    func createChannel(req: Request) async throws -> GroupChannel {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let group = try await GroupsService.group(Self.uuid("groupId", on: req), on: req.db)
        let groupId = try group.requireID()
        try await GroupsService.requireManager(GroupsService.requireMember(group, viewer: viewer, on: req.db))
        let body = try req.content.decode(CreateGroupChannelRequest.self)
        let name = try GroupsValidation.channelName(body.name)
        let topic = try GroupsValidation.channelTopic(body.topic)

        let existing = try await GroupsService.channels(groupIds: [groupId], on: req.db)
        guard existing.count < GroupsValidation.maxChannels else {
            throw CodedAbort(
                status: .conflict,
                code: "channel_limit",
                reason: "A group can have up to \(GroupsValidation.maxChannels) channels."
            )
        }
        guard !existing.contains(where: { $0.name == name }) else {
            throw CodedAbort(status: .conflict, code: "channel_name_taken", reason: "There's already a #\(name).")
        }
        let channel = GroupChannelRecord(
            groupId: groupId,
            name: name,
            topic: topic,
            position: (existing.map(\.position).max() ?? -1) + 1
        )
        try await channel.create(on: req.db)
        try await announce(.channelCreated, groupId, channelId: channel.requireID(), on: req)
        return try GroupsService.channelDTO(channel, read: nil)
    }

    @Sendable
    func updateChannel(req: Request) async throws -> GroupChannel {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let (channel, group) = try await GroupsService.channel(Self.uuid("channelId", on: req), on: req.db)
        try await GroupsService.requireManager(GroupsService.requireMember(group, viewer: viewer, on: req.db))
        let body = try req.content.decode(UpdateGroupChannelRequest.self)
        if let raw = body.name {
            let name = try GroupsValidation.channelName(raw)
            if name != channel.name {
                let taken = try await GroupChannelRecord.query(on: req.db)
                    .filter(\.$groupId == channel.groupId)
                    .filter(\.$name == name)
                    .first() != nil
                guard !taken else {
                    throw CodedAbort(status: .conflict, code: "channel_name_taken", reason: "There's already a #\(name).")
                }
                channel.name = name
            }
        }
        if let topic = body.topic {
            channel.topic = try GroupsValidation.channelTopic(topic)
        }
        if let position = body.position {
            channel.position = max(0, min(position, GroupsValidation.maxChannels))
        }
        try await channel.save(on: req.db)
        let hidden = try await SocialService.blockedEitherWay(for: viewer.userId, on: req.db)
        let read = try await GroupsService.readState(
            channelIds: [channel.requireID()], userId: viewer.userId, hidden: hidden, on: req.db
        )
        try await announce(.channelUpdated, channel.groupId, channelId: channel.requireID(), on: req)
        return try GroupsService.channelDTO(channel, read: channel.id.flatMap { read[$0] })
    }

    @Sendable
    func deleteChannel(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        let (channel, group) = try await GroupsService.channel(Self.uuid("channelId", on: req), on: req.db)
        try await GroupsService.requireManager(GroupsService.requireMember(group, viewer: viewer, on: req.db))
        let count = try await GroupChannelRecord.query(on: req.db).filter(\.$groupId == channel.groupId).count()
        guard count > 1 else {
            throw CodedAbort(status: .conflict, code: "last_channel", reason: "A group needs at least one channel.")
        }
        try await channel.delete(on: req.db)
        try await announce(.channelDeleted, channel.groupId, channelId: channel.requireID(), on: req)
        return .noContent
    }

    // MARK: - Invite links

    /// Any member can make a link: with no users yet, every invite matters.
    @Sendable
    func createInviteLink(req: Request) async throws -> GroupInviteLink {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let group = try await GroupsService.group(Self.uuid("groupId", on: req), on: req.db)
        let groupId = try group.requireID()
        _ = try await GroupsService.requireMember(group, viewer: viewer, on: req.db)
        let body = (try? req.content.decode(CreateGroupInviteRequest.self)) ?? .default
        let (expiresAt, maxUses) = try GroupsValidation.invite(body)

        let active = try await activeLinks(groupId, on: req.db)
        guard active.count < GroupsValidation.maxActiveInviteLinks else {
            throw CodedAbort(
                status: .conflict,
                code: "invite_limit",
                reason: "This group has \(GroupsValidation.maxActiveInviteLinks) active invite links. Revoke one first."
            )
        }
        let invite = GroupInviteRecord(
            groupId: groupId,
            createdBy: viewer.userId,
            code: InviteCode.generate(),
            inviteeId: nil,
            expiresAt: expiresAt,
            maxUses: maxUses
        )
        try await invite.create(on: req.db)
        return try GroupsService.inviteLinkDTO(invite, usernames: viewer.username.map { [viewer.userId: $0] } ?? [:])
    }

    /// Owner and admins see every active link; members see their own.
    @Sendable
    func inviteLinks(req: Request) async throws -> GroupInviteLinkList {
        let viewer = try req.communityViewer
        let group = try await GroupsService.group(Self.uuid("groupId", on: req), on: req.db)
        let member = try await GroupsService.requireMember(group, viewer: viewer, on: req.db)
        var links = try await activeLinks(group.requireID(), on: req.db)
        if !GroupsService.role(member).canManage {
            links = links.filter { $0.createdBy == viewer.userId }
        }
        let names = try await BoardsService.usernames(for: links.compactMap(\.createdBy), on: req.db)
        return try GroupInviteLinkList(items: links.map { try GroupsService.inviteLinkDTO($0, usernames: names) })
    }

    @Sendable
    func revokeInvite(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        guard let invite = try await GroupInviteRecord.find(Self.uuid("inviteId", on: req), on: req.db) else {
            throw Abort(.notFound, reason: "Invite not found")
        }
        let group = try await GroupsService.group(invite.groupId, on: req.db)
        let member = try await GroupsService.requireMember(group, viewer: viewer, on: req.db)
        guard invite.createdBy == viewer.userId || GroupsService.role(member).canManage else {
            throw CodedAbort(status: .forbidden, code: "group_forbidden", reason: "Only the invite's creator or an admin can revoke it.")
        }
        if invite.revokedAt == nil {
            invite.revokedAt = Date()
            try await invite.save(on: req.db)
        }
        return .noContent
    }

    @Sendable
    func previewInvite(req: Request) async throws -> GroupInvitePreview {
        let viewer = try req.communityViewer
        let (invite, group) = try await usableLink(code: req.parameters.get("code") ?? "", viewer: viewer, on: req.db)
        let hidden = try await SocialService.blockedEitherWay(for: viewer.userId, on: req.db)
        let summary = try await GroupsService.summaries([group], viewerId: viewer.userId, hidden: hidden, on: req.db)[0]
        let names = try await BoardsService.usernames(for: invite.createdBy.map { [$0] } ?? [], on: req.db)
        return GroupInvitePreview(
            code: invite.code ?? "",
            group: summary,
            inviterUsername: invite.createdBy.flatMap { names[$0] },
            alreadyMember: summary.membership != nil,
            expiresAt: invite.expiresAt
        )
    }

    /// Joins through a link. Redeeming a link you've already used is a no-op
    /// that returns the group, so a double tap never fails.
    @Sendable
    func redeemInvite(req: Request) async throws -> GroupDetail {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let code = req.parameters.get("code") ?? ""
        if InviteCode.isWellFormed(code),
           let invite = try await GroupInviteRecord.query(on: req.db).filter(\.$code == code).first(),
           let group = try await GroupRecord.find(invite.groupId, on: req.db),
           try await GroupsService.membership(groupId: invite.groupId, userId: viewer.userId, on: req.db) != nil
        {
            return try await GroupsService.detail(group, viewer: viewer, on: req.db)
        }
        let (invite, group) = try await usableLink(code: code, viewer: viewer, on: req.db)
        let inviteId = try invite.requireID()
        try await req.db.transaction { tx in
            // Claims a use atomically, so two redeems racing for the last
            // use can't both get in.
            let claimed = try await GroupsService.sql(tx).raw("""
            UPDATE group_invites SET uses = uses + 1
            WHERE id = \(bind: inviteId) AND revoked_at IS NULL
              AND (expires_at IS NULL OR expires_at > \(bind: Date()))
              AND (max_uses IS NULL OR uses < max_uses)
            RETURNING id
            """).all()
            guard !claimed.isEmpty else {
                throw CodedAbort(status: .gone, code: "invite_exhausted", reason: "This invite has been used up.")
            }
            try await GroupsService.addMember(group, userId: viewer.userId, role: .member, pushEnabled: true, on: tx)
        }
        req.scheduleAchievementCheck(for: viewer.userId)
        try await announce(.groupUpdated, group.requireID(), on: req)
        return try await GroupsService.detail(group, viewer: viewer, on: req.db)
    }

    // MARK: - Direct invitations

    /// Invites friends by id. People who aren't friends, are blocked either
    /// way, already belong, are banned or already have a pending invitation
    /// are skipped quietly, so the response never reveals why.
    @Sendable
    func inviteFriends(req: Request) async throws -> GroupDirectInvitationResponse {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let group = try await GroupsService.group(Self.uuid("groupId", on: req), on: req.db)
        let groupId = try group.requireID()
        _ = try await GroupsService.requireMember(group, viewer: viewer, on: req.db)
        let userIds = try Array(Set(req.content.decode(GroupDirectInvitationRequest.self).userIds))
        guard userIds.count <= GroupsValidation.maxDirectInvitations else {
            throw Abort(.badRequest, reason: "Invite up to \(GroupsValidation.maxDirectInvitations) people at a time.")
        }

        let friends = try await SocialService.friendIds(of: viewer.userId, on: req.db)
        let hidden = try await SocialService.blockedEitherWay(for: viewer.userId, on: req.db)
        let members = try await GroupMemberRecord.query(on: req.db)
            .filter(\.$groupId == groupId)
            .filter(\.$userId ~~ userIds)
            .all()
            .map(\.userId)
        let banned = try await GroupBanRecord.query(on: req.db)
            .filter(\.$groupId == groupId)
            .filter(\.$userId ~~ userIds)
            .all()
            .map(\.userId)
        let pending = try await GroupInviteRecord.query(on: req.db)
            .filter(\.$groupId == groupId)
            .filter(\.$inviteeId ~~ userIds.map { Optional($0) })
            .filter(\.$acceptedAt == nil)
            .filter(\.$revokedAt == nil)
            .all()
            .compactMap(\.inviteeId)
        let skip = Set(members).union(banned).union(pending).union(hidden)
        let targets = userIds.filter { friends.contains($0) && !skip.contains($0) && $0 != viewer.userId }

        try await req.db.transaction { tx in
            for target in targets {
                try await GroupInviteRecord(
                    groupId: groupId,
                    createdBy: viewer.userId,
                    code: nil,
                    inviteeId: target,
                    expiresAt: nil,
                    maxUses: nil
                ).create(on: tx)
            }
        }
        try await GroupsRealtime.publish(
            GroupRealtimeEvent(type: .invitationReceived, groupId: group.requireID()), to: Set(targets), on: req
        )
        GroupNotifier.invited(targets, groupId: groupId, groupName: group.name, inviterUsername: viewer.username, app: req.application)
        return GroupDirectInvitationResponse(invitedUserIds: targets)
    }

    @Sendable
    func invitations(req: Request) async throws -> GroupInvitationList {
        let viewer = try req.communityViewer
        let hidden = try await SocialService.blockedEitherWay(for: viewer.userId, on: req.db)
        let pending = try await GroupsService.pendingInvitations(for: viewer.userId, hidden: hidden, on: req.db)
        let groups = try await GroupRecord.query(on: req.db).filter(\.$id ~~ pending.map(\.groupId)).all()
        let summaries = try await GroupsService.summaries(groups, viewerId: viewer.userId, hidden: hidden, on: req.db)
        let summaryById = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let names = try await BoardsService.usernames(for: pending.compactMap(\.createdBy), on: req.db)
        return try GroupInvitationList(items: pending.compactMap { invite in
            guard let group = summaryById[invite.groupId] else { return nil }
            return try GroupInvitation(
                id: invite.requireID(),
                group: group,
                inviterUsername: invite.createdBy.flatMap { names[$0] },
                createdAt: invite.createdAt ?? Date()
            )
        })
    }

    @Sendable
    func acceptInvitation(req: Request) async throws -> GroupDetail {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let invite = try await pendingInvitation(req: req, viewer: viewer)
        let group = try await GroupsService.group(invite.groupId, on: req.db)
        try await req.db.transaction { tx in
            invite.acceptedAt = Date()
            try await invite.save(on: tx)
            if try await GroupsService.membership(groupId: invite.groupId, userId: viewer.userId, on: tx) == nil {
                try await GroupsService.addMember(group, userId: viewer.userId, role: .member, pushEnabled: true, on: tx)
            }
        }
        req.scheduleAchievementCheck(for: viewer.userId)
        try await announce(.groupUpdated, group.requireID(), on: req)
        return try await GroupsService.detail(group, viewer: viewer, on: req.db)
    }

    @Sendable
    func declineInvitation(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        let invite = try await pendingInvitation(req: req, viewer: viewer)
        invite.revokedAt = Date()
        try await invite.save(on: req.db)
        return .noContent
    }

    // MARK: - Helpers

    private func requireTarget(_ group: GroupRecord, req: Request) async throws -> GroupMemberRecord {
        guard let target = try await GroupsService.membership(
            groupId: group.requireID(), userId: Self.uuid("userId", on: req), on: req.db
        ) else {
            throw Abort(.notFound, reason: "Member not found")
        }
        return target
    }

    /// Moderating someone needs a strictly higher role; a global admin can
    /// moderate anyone but the owner.
    private func requireOutranks(
        _ group: GroupRecord,
        target: GroupMemberRecord,
        viewer: CommunityViewer,
        on db: any Database
    ) async throws {
        guard target.userId != viewer.userId else {
            throw Abort(.badRequest, reason: "Leave the group instead.")
        }
        if viewer.isAdmin, GroupsService.role(target) != .owner {
            return
        }
        let actor = try await GroupsService.requireMember(group, viewer: viewer, on: db)
        guard GroupsService.role(actor).canManage,
              GroupsService.rank(GroupsService.role(actor)) > GroupsService.rank(GroupsService.role(target))
        else {
            throw CodedAbort(status: .forbidden, code: "group_forbidden", reason: "You can't remove that member.")
        }
    }

    private func activeLinks(_ groupId: UUID, on db: any Database) async throws -> [GroupInviteRecord] {
        let now = Date()
        return try await GroupInviteRecord.query(on: db)
            .filter(\.$groupId == groupId)
            .filter(\.$code != nil)
            .filter(\.$revokedAt == nil)
            .sort(\.$createdAt, .descending)
            .all()
            .filter { invite in
                (invite.expiresAt.map { $0 > now } ?? true) && (invite.maxUses.map { invite.uses < $0 } ?? true)
            }
    }

    /// A link that can still be used. A blocked inviter, a deleted group or a
    /// malformed code all read as "not found"; spent links say why.
    private func usableLink(
        code: String,
        viewer: CommunityViewer,
        on db: any Database
    ) async throws -> (GroupInviteRecord, GroupRecord) {
        guard InviteCode.isWellFormed(code),
              let invite = try await GroupInviteRecord.query(on: db).filter(\.$code == code).first(),
              invite.revokedAt == nil,
              let group = try await GroupRecord.find(invite.groupId, on: db)
        else {
            throw Abort(.notFound, reason: "Invite not found")
        }
        if let inviter = invite.createdBy, try await SocialService.isBlockedEitherWay(viewer.userId, inviter, on: db) {
            throw Abort(.notFound, reason: "Invite not found")
        }
        if let expiresAt = invite.expiresAt, expiresAt <= Date() {
            throw CodedAbort(status: .gone, code: "invite_expired", reason: "This invite has expired.")
        }
        if let maxUses = invite.maxUses, invite.uses >= maxUses {
            throw CodedAbort(status: .gone, code: "invite_exhausted", reason: "This invite has been used up.")
        }
        return (invite, group)
    }

    private func pendingInvitation(req: Request, viewer: CommunityViewer) async throws -> GroupInviteRecord {
        guard let invite = try await GroupInviteRecord.find(Self.uuid("inviteId", on: req), on: req.db),
              invite.inviteeId == viewer.userId,
              invite.acceptedAt == nil,
              invite.revokedAt == nil,
              try await GroupRecord.find(invite.groupId, on: req.db) != nil
        else {
            throw Abort(.notFound, reason: "Invitation not found")
        }
        return invite
    }

    /// Tells every member something about the group changed; clients refetch.
    private func announce(_ type: GroupRealtimeEventType, _ groupId: UUID, channelId: UUID? = nil, on req: Request) async {
        await GroupsRealtime.publish(GroupRealtimeEvent(type: type, groupId: groupId, channelId: channelId), toMembersOf: groupId, on: req)
    }

    private func removed(_ userId: UUID, from groupId: UUID, reason: GroupMembershipRemovalReason, on req: Request) async {
        await GroupsRealtime.publish(
            GroupRealtimeEvent(type: .membershipRemoved, groupId: groupId, reason: reason), to: [userId], on: req
        )
    }

    static func uuid(_ name: String, on req: Request) throws -> UUID {
        try BoardsController.uuid(name, on: req)
    }
}
