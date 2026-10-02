import Fluent
import Foundation
import Vapor

/// `/v1/social`: friends, requests, invites, privacy, blocks, reports and
/// discovery. First-party sessions only; `GET /social/config` always answers
/// so the app can tell "off" from "broken".
struct SocialController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let social = routes.grouped("social")
            .grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        social.get("config", use: config)

        let enabled = social.grouped(SocialEnabledMiddleware())
        enabled.grouped(RateLimitMiddleware(limit: 60, interval: 60, keyPrefix: "ratelimit:social-search"))
            .get("users", "search", use: search)
        enabled.get("users", ":userId", use: profile)

        enabled.get("friends", use: friends)
        enabled.delete("friends", ":userId", use: unfriend)

        enabled.get("friend-requests", use: requests)
        enabled.post("friend-requests", use: sendRequest)
        enabled.post("friend-requests", ":requestId", "accept", use: accept)
        enabled.post("friend-requests", ":requestId", "decline", use: decline)
        enabled.delete("friend-requests", ":requestId", use: cancel)

        enabled.post("invites", use: createInvite)
        enabled.get("invites", ":code", use: invitePreview)
        enabled.post("invites", ":code", "redeem", use: redeemInvite)

        enabled.get("privacy", use: privacy)
        enabled.put("privacy", use: updatePrivacy)

        enabled.get("blocks", use: blocks)
        enabled.post("blocks", ":userId", use: block)
        enabled.delete("blocks", ":userId", use: unblock)

        enabled.grouped(RateLimitMiddleware(limit: 10, interval: 60, keyPrefix: "ratelimit:social-report"))
            .post("reports", use: report)

        let discovery = enabled.grouped("discovery")
            .grouped(RateLimitMiddleware(limit: 10, interval: 60, keyPrefix: "ratelimit:social-discovery"))
        discovery.post("contacts", "match", use: matchContacts)
        discovery.post("x", "start", use: XFollowingImport.start)
        discovery.post("x", "exchange", use: XFollowingImport.exchange)
        discovery.post("facebook", "limited", use: FacebookFriendsImport.limited)
        discovery.post("facebook", "start", use: FacebookFriendsImport.start)
        discovery.post("facebook", "exchange", use: FacebookFriendsImport.exchange)
        discovery.delete("facebook", use: FacebookFriendsImport.disconnect)
    }

    // MARK: - Config

    @Sendable
    func config(req: Request) async throws -> SocialConfigDTO {
        let userId = try req.auth.require(SessionToken.self).userId
        let config = SocialConfiguration.fromEnvironment()
        if config.enabled {
            // Keeps this user's contact hash current, which is what makes them
            // findable from their friends' address books.
            try await SocialService.ensureSettings(for: userId, config: config, on: req.db)
        }
        return config.dto
    }

    // MARK: - People

    @Sendable
    func search(req: Request) async throws -> SocialUserSearchResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        let query = (try? req.query.get(String.self, at: "q")) ?? ""
        let users = try await SocialService.search(query: query, viewer: userId, on: req.db)
        return SocialUserSearchResponse(users: users, nextCursor: nil)
    }

    @Sendable
    func profile(req: Request) async throws -> SocialProfileDTO {
        let viewer = try req.auth.require(SessionToken.self).userId
        let target = try Self.uuidParameter("userId", on: req)
        try await Self.requireVisible(target, viewer: viewer, on: req.db)
        let summary = try await SocialService.summary(of: target, viewer: viewer, on: req.db)
        let user = try await User.find(target, on: req.db)
        // Stats follow the owner's privacy settings; people always see their own.
        let stats = try await XPService.profileStats(
            of: target,
            viewer: viewer,
            timeZone: GamificationCalendar.timeZone(from: req),
            on: req.db
        )
        return SocialProfileDTO(
            user: summary,
            streakDays: stats.streakDays,
            xpLevel: stats.xpLevel,
            badgeCount: nil,
            joinedAt: user?.createdAt
        )
    }

    @Sendable
    func friends(req: Request) async throws -> SocialFriendsListResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        let hidden = try await SocialService.blockedEitherWay(for: userId, on: req.db)
        let ids = try await SocialService.friendIds(of: userId, on: req.db).subtracting(hidden)
        let summaries = try await SocialService.summaries(for: Array(ids), viewer: userId, on: req.db)
        let friends = summaries.values.sorted { $0.username < $1.username }
        return SocialFriendsListResponse(friends: friends, nextCursor: nil)
    }

    @Sendable
    func unfriend(req: Request) async throws -> HTTPStatus {
        let userId = try req.auth.require(SessionToken.self).userId
        let target = try Self.uuidParameter("userId", on: req)
        try await SocialService.unfriend(userId, target, on: req.db)
        return .noContent
    }

    // MARK: - Requests

    @Sendable
    func requests(req: Request) async throws -> SocialFriendRequestsResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        return try await SocialService.requests(for: userId, on: req.db)
    }

    /// Idempotent. When the other person already asked, this accepts their
    /// request instead of creating a second one.
    @Sendable
    func sendRequest(req: Request) async throws -> SocialFriendRequestDTO {
        let userId = try req.auth.require(SessionToken.self).userId
        let target = try req.content.decode(SocialSendFriendRequestBody.self).userId
        guard target != userId else {
            throw Abort(.badRequest, reason: "You can't add yourself.")
        }
        try await Self.requireVisible(target, viewer: userId, on: req.db)
        if try await SocialService.areFriends(userId, target, on: req.db) {
            throw Abort(.conflict, reason: "You're already friends.")
        }

        if let reverse = try await SocialFriendRequest.query(on: req.db)
            .filter(\.$fromUserId == target)
            .filter(\.$toUserId == userId)
            .first()
        {
            let summaries = try await SocialService.summaries(for: [userId, target], viewer: userId, on: req.db)
            let dto = SocialService.dto(for: reverse, summaries: summaries)
            try await SocialService.befriend(userId, target, on: req.db)
            await Self.push(.friendAccepted, to: target, about: userId, on: req)
            guard let dto else { throw Abort(.internalServerError, reason: "Friend request missing") }
            return dto
        }

        let request: SocialFriendRequest
        if let existing = try await SocialFriendRequest.query(on: req.db)
            .filter(\.$fromUserId == userId)
            .filter(\.$toUserId == target)
            .first()
        {
            request = existing
        } else {
            request = SocialFriendRequest(fromUserId: userId, toUserId: target)
            try await request.save(on: req.db)
            await Self.push(.friendRequest, to: target, about: userId, on: req)
        }
        let summaries = try await SocialService.summaries(for: [userId, target], viewer: userId, on: req.db)
        guard let dto = SocialService.dto(for: request, summaries: summaries) else {
            throw Abort(.internalServerError, reason: "Friend request missing")
        }
        return dto
    }

    @Sendable
    func accept(req: Request) async throws -> HTTPStatus {
        let userId = try req.auth.require(SessionToken.self).userId
        let request = try await Self.incomingRequest(on: req, to: userId)
        try await SocialService.befriend(userId, request.fromUserId, on: req.db)
        await Self.push(.friendAccepted, to: request.fromUserId, about: userId, on: req)
        return .noContent
    }

    /// The requester is not told.
    @Sendable
    func decline(req: Request) async throws -> HTTPStatus {
        let userId = try req.auth.require(SessionToken.self).userId
        let request = try await Self.incomingRequest(on: req, to: userId)
        try await request.delete(on: req.db)
        return .noContent
    }

    @Sendable
    func cancel(req: Request) async throws -> HTTPStatus {
        let userId = try req.auth.require(SessionToken.self).userId
        let requestId = try Self.uuidParameter("requestId", on: req)
        guard let request = try await SocialFriendRequest.find(requestId, on: req.db), request.fromUserId == userId else {
            throw Abort(.notFound, reason: "Friend request not found")
        }
        try await request.delete(on: req.db)
        return .noContent
    }

    // MARK: - Invites

    @Sendable
    func createInvite(req: Request) async throws -> SocialInviteLinkDTO {
        let userId = try req.auth.require(SessionToken.self).userId
        return try await SocialService.invite(for: userId, config: SocialConfiguration.fromEnvironment(), on: req.db)
    }

    @Sendable
    func invitePreview(req: Request) async throws -> SocialUserSummaryDTO {
        let userId = try req.auth.require(SessionToken.self).userId
        let inviter = try await SocialService.inviter(code: Self.codeParameter(on: req), viewer: userId, on: req.db)
        return try await SocialService.summary(of: inviter, viewer: userId, on: req.db)
    }

    /// The inviter asked by sharing the link, so redeeming befriends straight away.
    @Sendable
    func redeemInvite(req: Request) async throws -> SocialInviteRedeemResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        let inviter = try await SocialService.inviter(code: Self.codeParameter(on: req), viewer: userId, on: req.db)
        guard inviter != userId else {
            throw Abort(.badRequest, reason: "That's your own invite link.")
        }
        let alreadyFriends = try await SocialService.areFriends(userId, inviter, on: req.db)
        if !alreadyFriends {
            try await SocialService.befriend(userId, inviter, on: req.db)
            await Self.push(.friendAccepted, to: inviter, about: userId, on: req)
        }
        return try await SocialInviteRedeemResponse(inviter: SocialService.summary(of: inviter, viewer: userId, on: req.db))
    }

    // MARK: - Privacy

    @Sendable
    func privacy(req: Request) async throws -> SocialPrivacySettingsDTO {
        let userId = try req.auth.require(SessionToken.self).userId
        return try await SocialService.ensureSettings(
            for: userId,
            config: SocialConfiguration.fromEnvironment(),
            on: req.db
        ).dto
    }

    @Sendable
    func updatePrivacy(req: Request) async throws -> SocialPrivacySettingsDTO {
        let userId = try req.auth.require(SessionToken.self).userId
        var settings = try req.content.decode(SocialPrivacySettingsDTO.self)
        let record = try await SocialService.ensureSettings(
            for: userId,
            config: SocialConfiguration.fromEnvironment(),
            on: req.db
        )
        if try req.content.decode(SocialFacebookPrivacyProbe.self).discoverableByFacebook == nil {
            settings.discoverableByFacebook = record.discoverableByFacebook
        }
        record.apply(settings)
        try await record.save(on: req.db)
        return record.dto
    }

    // MARK: - Safety

    @Sendable
    func blocks(req: Request) async throws -> SocialBlockedUsersResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        let rows = try await SocialBlock.query(on: req.db)
            .filter(\.$blockerId == userId)
            .sort(\.$createdAt, .descending)
            .all()
        let summaries = try await SocialService.summaries(for: rows.map(\.blockedId), viewer: userId, on: req.db)
        return SocialBlockedUsersResponse(users: rows.compactMap { summaries[$0.blockedId] })
    }

    /// Ends the friendship and pending requests both ways. Idempotent.
    @Sendable
    func block(req: Request) async throws -> HTTPStatus {
        let userId = try req.auth.require(SessionToken.self).userId
        let target = try Self.uuidParameter("userId", on: req)
        guard target != userId else {
            throw Abort(.badRequest, reason: "You can't block yourself.")
        }
        guard try await User.find(target, on: req.db) != nil else {
            throw Abort(.notFound, reason: "User not found")
        }
        try await req.db.transaction { tx in
            let exists = try await SocialBlock.query(on: tx)
                .filter(\.$blockerId == userId)
                .filter(\.$blockedId == target)
                .first() != nil
            if !exists {
                try await SocialBlock(blockerId: userId, blockedId: target).save(on: tx)
            }
            try await SocialService.unfriend(userId, target, on: tx)
            try await SocialService.deleteRequests(between: userId, target, on: tx)
        }
        return .noContent
    }

    @Sendable
    func unblock(req: Request) async throws -> HTTPStatus {
        let userId = try req.auth.require(SessionToken.self).userId
        let target = try Self.uuidParameter("userId", on: req)
        try await SocialBlock.query(on: req.db)
            .filter(\.$blockerId == userId)
            .filter(\.$blockedId == target)
            .delete()
        return .noContent
    }

    @Sendable
    func report(req: Request) async throws -> HTTPStatus {
        let userId = try req.auth.require(SessionToken.self).userId
        let body = try req.content.decode(SocialReportBody.self)
        let targetId = body.targetId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetId.isEmpty, targetId.count <= 100 else {
            throw Abort(.badRequest, reason: "A report needs a target.")
        }
        let note = body.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (note?.count ?? 0) <= 1000 else {
            throw Abort(.badRequest, reason: "Keep the details under 1,000 characters.")
        }
        try await SocialReport(
            reporterId: userId,
            targetType: body.targetType.rawValue,
            targetId: targetId,
            reason: body.reason.rawValue,
            note: (note?.isEmpty ?? true) ? nil : note
        ).save(on: req.db)
        req.logger.notice("social.report filed target_type=\(body.targetType.rawValue) reason=\(body.reason.rawValue)")
        await SocialModeration.notifyNewReport(
            targetType: body.targetType, targetId: targetId, reason: body.reason, on: req
        )
        return .accepted
    }

    // MARK: - Discovery

    /// Matches on-device hashes of the caller's contacts against users who
    /// allow it. Nothing submitted is stored.
    @Sendable
    func matchContacts(req: Request) async throws -> SocialContactMatchResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        let config = SocialConfiguration.fromEnvironment()
        guard config.contactsDiscovery else {
            throw Abort(.notFound, reason: "Contact matching is not available.")
        }
        let body = try req.content.decode(SocialContactMatchBody.self)
        guard body.hashVersion == SocialConfiguration.contactHashVersion else {
            throw Abort(.unprocessableEntity, reason: "Unsupported contact hash version.")
        }
        guard body.items.count <= 1000 else {
            throw Abort(.payloadTooLarge, reason: "Send at most 1,000 contacts per request.")
        }
        try await SocialService.ensureSettings(for: userId, config: config, on: req.db)

        let hashes = Array(Set(body.items.filter { $0.kind == .email }.map(\.hash).filter(SocialContactHash.isWellFormed)))
        guard !hashes.isEmpty else { return SocialContactMatchResponse(matches: []) }

        let rows = try await SocialSettingsRecord.query(on: req.db)
            .filter(\.$emailHash ~~ hashes)
            .filter(\.$discoverableByContacts == true)
            .filter(\.$userId != userId)
            .all()
        let hidden = try await SocialService.blockedEitherWay(for: userId, on: req.db)
        let visible = rows.filter { !hidden.contains($0.userId) }
        let summaries = try await SocialService.summaries(for: visible.map(\.userId), viewer: userId, on: req.db)
        let matches = visible.compactMap { row -> SocialContactMatch? in
            guard let hash = row.emailHash, let user = summaries[row.userId] else { return nil }
            return SocialContactMatch(hash: hash, user: user)
        }
        return SocialContactMatchResponse(matches: matches)
    }

    // MARK: - Helpers

    static func uuidParameter(_ name: String, on req: Request) throws -> UUID {
        guard let value = req.parameters.get(name, as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid \(name)")
        }
        return value
    }

    static func codeParameter(on req: Request) throws -> String {
        guard let code = req.parameters.get("code"),
              (4 ... 64).contains(code.count),
              code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else {
            throw Abort(.notFound, reason: "Invite not found")
        }
        return code
    }

    /// 404 for missing users and for blocks in either direction.
    static func requireVisible(_ target: UUID, viewer: UUID, on db: any Database) async throws {
        guard try await User.find(target, on: db) != nil else {
            throw Abort(.notFound, reason: "User not found")
        }
        if try await SocialService.isBlockedEitherWay(viewer, target, on: db) {
            throw Abort(.notFound, reason: "User not found")
        }
    }

    static func incomingRequest(on req: Request, to userId: UUID) async throws -> SocialFriendRequest {
        let requestId = try uuidParameter("requestId", on: req)
        guard let request = try await SocialFriendRequest.find(requestId, on: req.db), request.toUserId == userId else {
            throw Abort(.notFound, reason: "Friend request not found")
        }
        return request
    }

    /// Best effort: a failed push never fails the request that caused it.
    static func push(_ kind: SocialPushMessage.Kind, to recipient: UUID, about actor: UUID, on req: Request) async {
        do {
            let devices = try await req.pushDeviceService.activeDevices(userId: recipient, on: req.db)
            guard !devices.isEmpty else { return }
            let name = try await User.find(actor, on: req.db)?.username.map { "@\($0)" } ?? "Someone"
            let message = switch kind {
            case .friendRequest:
                SocialPushMessage(kind: kind, title: "New friend request", body: "\(name) wants to be friends on Norviq.")
            case .friendAccepted:
                SocialPushMessage(kind: kind, title: "You're now friends", body: "\(name) is now your friend on Norviq.")
            }
            _ = await req.application.pushNotificationSender.sendSocialEvent(message: message, devices: devices, req: req)
        } catch {
            req.logger.warning("social.push failed kind=\(kind.rawValue) error=\(String(reflecting: type(of: error)))")
        }
    }
}

/// Every social route except `/config` 404s until `SOCIAL_ENABLED` is on,
/// and 403s for a user a moderator suspended.
struct SocialEnabledMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard SocialConfiguration.fromEnvironment().enabled else {
            throw Abort(.notFound)
        }
        if let userId = request.auth.get(SessionToken.self)?.userId,
           try await SocialService.isSuspended(userId, on: request.db)
        {
            throw Abort(.forbidden, reason: "Your access to friends features has been suspended.")
        }
        return try await next.respond(to: request)
    }
}
