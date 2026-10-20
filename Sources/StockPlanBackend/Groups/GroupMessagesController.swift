import Fluent
import FluentSQL
import Foundation
import StockPlanShared
import Vapor

/// `/v1/group-channels/:channelId/messages|read` and `/v1/group-messages`:
/// chat inside a group's channels. Sending is REST (idempotent by
/// `clientMessageId`, rate-limited, filtered); the realtime stream only
/// announces what REST already committed.
struct GroupMessagesController: RouteCollection {
    static let pageSize = 50

    func boot(routes: any RoutesBuilder) throws {
        let base = routes.grouped(
            ScopedBearerAuthenticator(),
            SessionToken.guardMiddleware(),
            FirstPartyOnlyMiddleware(),
            GroupsEnabledMiddleware(),
            CommunityAccessMiddleware()
        )

        let channels = base.grouped("group-channels")
        channels.grouped(RateLimitMiddleware(limit: 120, interval: 60, keyPrefix: "ratelimit:group-read"))
            .get(":channelId", "messages", use: messages)
        // The daily cap is enforced in the handler against the database.
        channels.grouped(RateLimitMiddleware(limit: 30, interval: 30, keyPrefix: "ratelimit:group-message"))
            .post(":channelId", "messages", use: send)
        channels.grouped(RateLimitMiddleware(limit: 120, interval: 60, keyPrefix: "ratelimit:group-mark-read"))
            .post(":channelId", "read", use: markRead)

        let messages = base.grouped("group-messages")
        messages.delete(":messageId", use: delete)
        messages.grouped(RateLimitMiddleware(limit: 20, interval: 3600, keyPrefix: "ratelimit:group-report"))
            .post(":messageId", "report", use: report)
    }

    /// Oldest first. With no cursor, the newest page; `before=<seq>` pages
    /// back, `after=<seq>` catches up. Messages from people hidden from the
    /// viewer are left out.
    @Sendable
    func messages(req: Request) async throws -> GroupMessagePage {
        let viewer = try req.communityViewer
        let (channel, group) = try await GroupsService.channel(GroupsController.uuid("channelId", on: req), on: req.db)
        let channelId = try channel.requireID()
        let member = try await GroupsService.requireMember(group, viewer: viewer, on: req.db)
        let limit = min(max(req.query[Int.self, at: "limit"] ?? Self.pageSize, 1), 100)
        let before = req.query[Int64.self, at: "before"]
        let after = req.query[Int64.self, at: "after"]
        guard before == nil || after == nil else {
            throw Abort(.badRequest, reason: "Use either before or after, not both.")
        }

        let hidden = try await SocialService.blockedEitherWay(for: viewer.userId, on: req.db)
        var query = GroupMessageRecord.query(on: req.db).filter(\.$channelId == channelId)
        if !hidden.isEmpty {
            query = query.filter(\.$authorId !~ Array(hidden))
        }
        var rows: [GroupMessageRecord]
        let hasMoreBefore: Bool
        let hasMoreAfter: Bool
        if let after {
            rows = try await query.filter(\.$seq > after).sort(\.$seq, .ascending).limit(limit + 1).all()
            hasMoreAfter = rows.count > limit
            rows = Array(rows.prefix(limit))
            hasMoreBefore = (rows.first?.seq ?? after + 1) > 1
        } else {
            if let before {
                query = query.filter(\.$seq < before)
            }
            rows = try await query.sort(\.$seq, .descending).limit(limit + 1).all()
            hasMoreBefore = rows.count > limit
            rows = Array(rows.prefix(limit)).reversed()
            hasMoreAfter = (rows.last?.seq ?? (before ?? 1) - 1) < channel.lastSeq
        }

        let read = try await GroupChannelRead.query(on: req.db)
            .filter(\.$channelId == channelId)
            .filter(\.$userId == member.userId)
            .first()
        let names = try await BoardsService.usernames(for: rows.map(\.authorId), on: req.db)
        return try GroupMessagePage(
            items: rows.map { try GroupsService.messageDTO($0, usernames: names) },
            hasMoreBefore: hasMoreBefore,
            hasMoreAfter: hasMoreAfter,
            lastReadSeq: read?.lastReadSeq ?? 0
        )
    }

    /// 201 with the new message, or 200 with the original when this
    /// `clientMessageId` was already sent, so a retry never posts twice.
    @Sendable
    func send(req: Request) async throws -> Response {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let (channel, group) = try await GroupsService.channel(GroupsController.uuid("channelId", on: req), on: req.db)
        let channelId = try channel.requireID()
        let groupId = try group.requireID()
        _ = try await GroupsService.requireMember(group, viewer: viewer, on: req.db)
        let request = try req.content.decode(SendGroupMessageRequest.self)
        let clientMessageId = try GroupsValidation.clientMessageId(request.clientMessageId)
        let names = viewer.username.map { [viewer.userId: $0] } ?? [:]

        if let existing = try await existingMessage(author: viewer.userId, clientMessageId: clientMessageId, on: req.db) {
            return try await GroupsService.messageDTO(existing, usernames: names).encodeResponse(status: .ok, for: req)
        }
        let body = try GroupsValidation.messageBody(request.body)

        let today = try await GroupMessageRecord.query(on: req.db)
            .filter(\.$authorId == viewer.userId)
            .filter(\.$createdAt > Date().addingTimeInterval(-86400))
            .count()
        guard today < GroupsValidation.maxMessagesPerDay else {
            throw CodedAbort(
                status: .tooManyRequests,
                code: "message_daily_limit",
                reason: "You've reached today's message limit. Try again tomorrow."
            )
        }

        let now = Date()
        let message: GroupMessageRecord
        do {
            message = try await req.db.transaction { tx in
                let sql = try GroupsService.sql(tx)
                // Locks the channel row, so seqs commit in order with no gaps.
                guard let row = try await sql.raw("""
                UPDATE group_channels SET last_seq = last_seq + 1, last_message_at = \(bind: now)
                WHERE id = \(bind: channelId) AND deleted_at IS NULL
                RETURNING last_seq
                """).first() else {
                    throw CodedAbort(status: .notFound, code: "channel_not_found", reason: "Channel not found")
                }
                let record = GroupMessageRecord()
                record.channelId = channelId
                record.groupId = groupId
                record.authorId = viewer.userId
                record.seq = try row.decode(column: "last_seq", as: Int64.self)
                record.clientMessageId = clientMessageId
                record.body = body
                record.createdAt = now
                try await record.create(on: tx)
                try await sql.raw("UPDATE groups SET last_message_at = \(bind: now) WHERE id = \(bind: groupId)").run()
                // Your own message is never unread to you.
                try await sql.raw("""
                INSERT INTO group_channel_reads (id, channel_id, user_id, last_read_seq, updated_at)
                VALUES (\(bind: UUID()), \(bind: channelId), \(bind: viewer.userId), \(bind: record.seq), \(bind: now))
                ON CONFLICT (channel_id, user_id) DO UPDATE
                SET last_read_seq = GREATEST(group_channel_reads.last_read_seq, EXCLUDED.last_read_seq),
                    updated_at = EXCLUDED.updated_at
                """).run()
                return record
            }
        } catch {
            // Two copies of the same send raced; the other one won.
            guard (error as? any DatabaseError)?.isConstraintFailure == true,
                  let existing = try await existingMessage(author: viewer.userId, clientMessageId: clientMessageId, on: req.db)
            else {
                throw error
            }
            return try await GroupsService.messageDTO(existing, usernames: names).encodeResponse(status: .ok, for: req)
        }
        let dto = try GroupsService.messageDTO(message, usernames: names)
        await GroupsRealtime.publish(
            GroupRealtimeEvent(type: .messageCreated, groupId: groupId, channelId: channelId, message: dto),
            toMembersOf: groupId,
            authorId: viewer.userId,
            on: req
        )
        GroupNotifier.messageCreated(
            dto, groupName: group.name, channelName: channel.name, authorUsername: viewer.username, app: req.application
        )
        return try await dto.encodeResponse(status: .created, for: req)
    }

    /// Moves the viewer's read marker forward; a lower seq is ignored.
    @Sendable
    func markRead(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        let (channel, group) = try await GroupsService.channel(GroupsController.uuid("channelId", on: req), on: req.db)
        let channelId = try channel.requireID()
        _ = try await GroupsService.requireMember(group, viewer: viewer, on: req.db)
        let seq = try min(max(req.content.decode(MarkGroupChannelReadRequest.self).seq, 0), channel.lastSeq)
        try await GroupsService.sql(req.db).raw("""
        INSERT INTO group_channel_reads (id, channel_id, user_id, last_read_seq, updated_at)
        VALUES (\(bind: UUID()), \(bind: channelId), \(bind: viewer.userId), \(bind: seq), \(bind: Date()))
        ON CONFLICT (channel_id, user_id) DO UPDATE
        SET last_read_seq = GREATEST(group_channel_reads.last_read_seq, EXCLUDED.last_read_seq),
            updated_at = EXCLUDED.updated_at
        """).run()
        // The viewer's other devices clear their badge.
        try await GroupsRealtime.publish(
            GroupRealtimeEvent(type: .channelRead, groupId: group.requireID(), channelId: channelId, seq: seq),
            to: [viewer.userId],
            on: req
        )
        return .noContent
    }

    /// The author, the group's owner or admins, or a global admin. Leaves a
    /// tombstone; the body is kept for moderators.
    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        guard let message = try await GroupMessageRecord.find(GroupsController.uuid("messageId", on: req), on: req.db) else {
            throw Abort(.notFound, reason: "Message not found")
        }
        let group = try await GroupsService.group(message.groupId, on: req.db)
        if message.authorId != viewer.userId, !viewer.isAdmin {
            try await GroupsService.requireManager(GroupsService.requireMember(group, viewer: viewer, on: req.db))
        }
        if message.deletedAt == nil {
            message.deletedAt = Date()
            message.deletedBy = viewer.userId
            try await message.save(on: req.db)
            try await GroupsRealtime.publish(
                GroupRealtimeEvent(
                    type: .messageDeleted,
                    groupId: message.groupId,
                    channelId: message.channelId,
                    messageId: message.requireID(),
                    seq: message.seq
                ),
                toMembersOf: message.groupId,
                on: req
            )
        }
        return .noContent
    }

    /// Lands in the same `social_reports` queue as board reports and pings
    /// Discord. Reporting skips the contribution gate: a muted member must
    /// still be able to protect themselves.
    @Sendable
    func report(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        guard let message = try await GroupMessageRecord.find(GroupsController.uuid("messageId", on: req), on: req.db) else {
            throw Abort(.notFound, reason: "Message not found")
        }
        let group = try await GroupsService.group(message.groupId, on: req.db)
        _ = try await GroupsService.requireMember(group, viewer: viewer, on: req.db)
        let body = try req.content.decode(GroupMessageReportRequest.self)
        let note = body.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (note?.count ?? 0) <= 1000 else {
            throw Abort(.badRequest, reason: "Keep the details under 1,000 characters.")
        }
        try await SocialReport(
            reporterId: viewer.userId,
            targetType: CommunityReportTarget.groupMessage,
            targetId: message.requireID().uuidString,
            reason: body.reason.rawValue,
            note: (note?.isEmpty ?? true) ? nil : note
        ).save(on: req.db)
        req.logger.notice("groups.report filed reason=\(body.reason.rawValue)")

        let reason = body.reason.rawValue
        let excerpt = message.body
        let groupName = group.name
        Task {
            do {
                try await req.discord.send(
                    "🚩 Group report (\(reason)) in \(groupName):\n```\(excerpt.prefix(300))```",
                    on: req
                )
            } catch {
                req.logger.debug("Failed to send discord group report notification")
            }
        }
        return .accepted
    }

    private func existingMessage(author: UUID, clientMessageId: String, on db: any Database) async throws -> GroupMessageRecord? {
        try await GroupMessageRecord.query(on: db)
            .filter(\.$authorId == author)
            .filter(\.$clientMessageId == clientMessageId)
            .first()
    }
}
