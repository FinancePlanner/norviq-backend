import Fluent
import Foundation
import Vapor

/// Friends graph rules. Blocking is invisible: anything that names a user who
/// blocked the caller, or whom the caller blocked, answers 404.
enum SocialService {
    // MARK: - Relationships

    static func friendIds(of userId: UUID, on db: any Database) async throws -> Set<UUID> {
        let rows = try await SocialFriendship.query(on: db).filter(\.$userId == userId).all()
        return Set(rows.map(\.friendId))
    }

    static func areFriends(_ a: UUID, _ b: UUID, on db: any Database) async throws -> Bool {
        try await SocialFriendship.query(on: db)
            .filter(\.$userId == a)
            .filter(\.$friendId == b)
            .first() != nil
    }

    /// People the viewer blocked plus people who blocked the viewer.
    static func blockedEitherWay(for viewer: UUID, on db: any Database) async throws -> Set<UUID> {
        let rows = try await SocialBlock.query(on: db)
            .group(.or) { group in
                group.filter(\.$blockerId == viewer).filter(\.$blockedId == viewer)
            }
            .all()
        return Set(rows.map { $0.blockerId == viewer ? $0.blockedId : $0.blockerId })
    }

    static func isBlockedEitherWay(_ a: UUID, _ b: UUID, on db: any Database) async throws -> Bool {
        try await blockedEitherWay(for: a, on: db).contains(b)
    }

    /// Summaries of `userIds` as `viewer` sees them, keyed by id. Users that
    /// no longer exist are simply absent.
    static func summaries(
        for userIds: [UUID],
        viewer: UUID,
        on db: any Database
    ) async throws -> [UUID: SocialUserSummaryDTO] {
        let ids = Array(Set(userIds))
        guard !ids.isEmpty else { return [:] }

        let users = try await User.query(on: db).filter(\.$id ~~ ids).all()
        let viewerFriends = try await friendIds(of: viewer, on: db)
        let viewerBlocked = try await SocialBlock.query(on: db)
            .filter(\.$blockerId == viewer)
            .filter(\.$blockedId ~~ ids)
            .all()
            .map(\.blockedId)
        let requests = try await SocialFriendRequest.query(on: db)
            .group(.or) { group in
                group
                    .group(.and) { $0.filter(\.$fromUserId == viewer).filter(\.$toUserId ~~ ids) }
                    .group(.and) { $0.filter(\.$toUserId == viewer).filter(\.$fromUserId ~~ ids) }
            }
            .all()

        var mutualCounts: [UUID: Int] = [:]
        if !viewerFriends.isEmpty {
            let mutualRows = try await SocialFriendship.query(on: db)
                .filter(\.$userId ~~ ids)
                .filter(\.$friendId ~~ Array(viewerFriends))
                .all()
            for row in mutualRows {
                mutualCounts[row.userId, default: 0] += 1
            }
        }

        let blockedSet = Set(viewerBlocked)
        var result: [UUID: SocialUserSummaryDTO] = [:]
        for user in users {
            guard let id = user.id else { continue }
            let status: SocialFriendshipStatus = if blockedSet.contains(id) {
                .blocked
            } else if viewerFriends.contains(id) {
                .friends
            } else if requests.contains(where: { $0.fromUserId == viewer && $0.toUserId == id }) {
                .outgoingPending
            } else if requests.contains(where: { $0.toUserId == viewer && $0.fromUserId == id }) {
                .incomingPending
            } else {
                .none
            }
            result[id] = SocialUserSummaryDTO(
                id: id,
                username: user.username ?? "user",
                displayName: nil,
                avatarUrl: user.avatarURLString,
                friendshipStatus: status,
                mutualFriendCount: id == viewer ? nil : mutualCounts[id]
            )
        }
        return result
    }

    static func summary(of userId: UUID, viewer: UUID, on db: any Database) async throws -> SocialUserSummaryDTO {
        guard let summary = try await summaries(for: [userId], viewer: viewer, on: db)[userId] else {
            throw Abort(.notFound, reason: "User not found")
        }
        return summary
    }

    // MARK: - Settings

    /// The user's settings row, created on first use. Also keeps the email
    /// hash current, so a changed address or a rotated pepper self-heals.
    @discardableResult
    static func ensureSettings(
        for userId: UUID,
        config: SocialConfiguration,
        on db: any Database
    ) async throws -> SocialSettingsRecord {
        let record = try await SocialSettingsRecord.query(on: db).filter(\.$userId == userId).first()
            ?? SocialSettingsRecord(userId: userId)
        var expectedHash: String?
        if let pepper = config.contactPepper, let user = try await User.find(userId, on: db) {
            expectedHash = SocialContactHash.hash(email: user.email, pepper: pepper)
        }
        if record.id == nil || record.emailHash != expectedHash {
            record.emailHash = expectedHash
            try await record.save(on: db)
        }
        return record
    }

    /// Settings for many users; users without a row get the defaults.
    static func settings(for userIds: [UUID], on db: any Database) async throws -> [UUID: SocialPrivacySettingsDTO] {
        guard !userIds.isEmpty else { return [:] }
        let rows = try await SocialSettingsRecord.query(on: db).filter(\.$userId ~~ userIds).all()
        var result = Dictionary(uniqueKeysWithValues: userIds.map { ($0, SocialPrivacySettingsDTO.default) })
        for row in rows {
            result[row.userId] = row.dto
        }
        return result
    }

    // MARK: - Search

    /// Username prefix search. Usernames are stored lowercased and limited to
    /// `[a-z0-9_]`, so anything else is dropped rather than escaped.
    static func search(query rawQuery: String, viewer: UUID, on db: any Database) async throws -> [SocialUserSummaryDTO] {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
        let query = String(rawQuery.lowercased().filter { allowed.contains($0) }.prefix(30))
        guard query.count >= 2 else { return [] }

        let escaped = query.replacingOccurrences(of: "_", with: "\\_")
        let candidates = try await User.query(on: db)
            .filter(\.$username, .custom("LIKE"), "\(escaped)%")
            .filter(\.$id != viewer)
            .sort(\.$username)
            .limit(40)
            .all()
            .compactMap(\.id)

        let hidden = try await blockedEitherWay(for: viewer, on: db)
        let visibleIds = candidates.filter { !hidden.contains($0) }
        let settings = try await settings(for: visibleIds, on: db)
        let summaries = try await summaries(for: visibleIds, viewer: viewer, on: db)

        let visible = visibleIds.compactMap { id -> SocialUserSummaryDTO? in
            guard let summary = summaries[id] else { return nil }
            if summary.friendshipStatus == .friends {
                return summary
            }
            switch settings[id]?.searchVisibility ?? .everyone {
            case .everyone: return summary
            case .friendsOfFriends: return (summary.mutualFriendCount ?? 0) > 0 ? summary : nil
            case .nobody: return nil
            }
        }
        return Array(visible.prefix(20))
    }

    // MARK: - Friend requests

    static func requests(for viewer: UUID, on db: any Database) async throws -> SocialFriendRequestsResponse {
        let rows = try await SocialFriendRequest.query(on: db)
            .group(.or) { $0.filter(\.$fromUserId == viewer).filter(\.$toUserId == viewer) }
            .sort(\.$createdAt, .descending)
            .all()
        let hidden = try await blockedEitherWay(for: viewer, on: db)
        let visible = rows.filter { !hidden.contains($0.fromUserId) && !hidden.contains($0.toUserId) }
        let summaries = try await summaries(
            for: visible.flatMap { [$0.fromUserId, $0.toUserId] },
            viewer: viewer,
            on: db
        )
        let dtos = visible.compactMap { dto(for: $0, summaries: summaries) }
        return SocialFriendRequestsResponse(
            incoming: dtos.filter { $0.to.id == viewer },
            outgoing: dtos.filter { $0.from.id == viewer }
        )
    }

    static func dto(
        for request: SocialFriendRequest,
        summaries: [UUID: SocialUserSummaryDTO]
    ) -> SocialFriendRequestDTO? {
        guard let id = request.id,
              let from = summaries[request.fromUserId],
              let to = summaries[request.toUserId]
        else { return nil }
        return SocialFriendRequestDTO(id: id, from: from, to: to, createdAt: request.createdAt ?? Date())
    }

    /// Writes both directions and clears pending requests between the two.
    static func befriend(_ a: UUID, _ b: UUID, on db: any Database) async throws {
        try await db.transaction { tx in
            for (user, friend) in [(a, b), (b, a)] {
                let exists = try await SocialFriendship.query(on: tx)
                    .filter(\.$userId == user)
                    .filter(\.$friendId == friend)
                    .first() != nil
                if !exists {
                    try await SocialFriendship(userId: user, friendId: friend).save(on: tx)
                }
            }
            try await deleteRequests(between: a, b, on: tx)
        }
    }

    static func unfriend(_ a: UUID, _ b: UUID, on db: any Database) async throws {
        try await SocialFriendship.query(on: db)
            .group(.or) { group in
                group
                    .group(.and) { $0.filter(\.$userId == a).filter(\.$friendId == b) }
                    .group(.and) { $0.filter(\.$userId == b).filter(\.$friendId == a) }
            }
            .delete()
    }

    static func deleteRequests(between a: UUID, _ b: UUID, on db: any Database) async throws {
        try await SocialFriendRequest.query(on: db)
            .group(.or) { group in
                group
                    .group(.and) { $0.filter(\.$fromUserId == a).filter(\.$toUserId == b) }
                    .group(.and) { $0.filter(\.$fromUserId == b).filter(\.$toUserId == a) }
            }
            .delete()
    }

    // MARK: - Invites

    static func invite(for userId: UUID, config: SocialConfiguration, on db: any Database) async throws -> SocialInviteLinkDTO {
        if let existing = try await SocialInvite.query(on: db).filter(\.$userId == userId).first() {
            return inviteDTO(existing.code, config: config)
        }
        // Collisions over 62^10 are not a practical concern; the unique index
        // is the backstop, and a retry from the client picks a fresh code.
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        let code = String((0 ..< 10).map { _ in alphabet.randomElement() ?? "x" })
        try await SocialInvite(userId: userId, code: code).save(on: db)
        return inviteDTO(code, config: config)
    }

    static func inviteDTO(_ code: String, config: SocialConfiguration) -> SocialInviteLinkDTO {
        let base = config.inviteBaseURL.hasSuffix("/") ? String(config.inviteBaseURL.dropLast()) : config.inviteBaseURL
        return SocialInviteLinkDTO(code: code, url: "\(base)/i/\(code)", expiresAt: nil)
    }

    /// The inviter behind `code`, unless either side blocked the other.
    static func inviter(code: String, viewer: UUID, on db: any Database) async throws -> UUID {
        guard let invite = try await SocialInvite.query(on: db).filter(\.$code == code).first() else {
            throw Abort(.notFound, reason: "Invite not found")
        }
        let blocked = try await isBlockedEitherWay(invite.userId, viewer, on: db)
        guard !blocked else {
            throw Abort(.notFound, reason: "Invite not found")
        }
        return invite.userId
    }
}
