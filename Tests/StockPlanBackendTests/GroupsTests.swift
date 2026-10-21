import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Groups validation")
struct GroupsValidationTests {
    @Test("Tickers drop '$', uppercase, allow class shares and pairs")
    func tickers() throws {
        #expect(try GroupsValidation.ticker("$aapl", topic: .stock) == "AAPL")
        #expect(try GroupsValidation.ticker(" brk.b ", topic: .stock) == "BRK.B")
        #expect(try GroupsValidation.ticker("btc-usd", topic: .crypto) == "BTC-USD")
        #expect(try GroupsValidation.ticker("", topic: .stock) == nil)
        #expect(throws: (any Error).self) { try GroupsValidation.ticker("AAPL!", topic: .stock) }
        #expect(throws: (any Error).self) { try GroupsValidation.ticker("-AAPL", topic: .stock) }
        #expect(throws: (any Error).self) { try GroupsValidation.ticker("AAPL", topic: .community) }
    }

    @Test("Channel names slugify spaces and reject everything else")
    func channelNames() throws {
        #expect(try GroupsValidation.channelName(" Earnings Talk ") == "earnings-talk")
        #expect(try GroupsValidation.channelName("off_topic") == "off-topic")
        #expect(throws: (any Error).self) { try GroupsValidation.channelName("") }
        #expect(throws: (any Error).self) { try GroupsValidation.channelName("ação") }
        #expect(throws: (any Error).self) { try GroupsValidation.channelName(String(repeating: "a", count: 33)) }
    }

    @Test("Names, icons and message bodies are bounded")
    func bounds() throws {
        #expect(try GroupsValidation.groupName("  $AAPL   holders ") == "$AAPL holders")
        #expect(throws: (any Error).self) { try GroupsValidation.groupName("a") }
        #expect(try GroupsValidation.iconEmoji("🍎") == "🍎")
        #expect(try GroupsValidation.iconEmoji("👨‍👩‍👧") == "👨‍👩‍👧")
        #expect(try GroupsValidation.iconEmoji(" ") == nil)
        #expect(throws: (any Error).self) { try GroupsValidation.iconEmoji("A") }
        #expect(throws: (any Error).self) { try GroupsValidation.iconEmoji("7") }
        #expect(throws: (any Error).self) { try GroupsValidation.iconEmoji("🍎🍏") }
        #expect(throws: (any Error).self) { try GroupsValidation.messageBody("   ") }
        #expect(throws: (any Error).self) { try GroupsValidation.messageBody(String(repeating: "x", count: 2001)) }
        #expect(try GroupsValidation.messageBody(" hi \n") == "hi")
    }

    @Test("Invite options: hours 1…720 or never, uses 1…1000 or unlimited")
    func inviteOptions() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let (expiresAt, maxUses) = try GroupsValidation.invite(.default, now: now)
        #expect(expiresAt == now.addingTimeInterval(168 * 3600))
        #expect(maxUses == nil)
        #expect(try GroupsValidation.invite(CreateGroupInviteRequest(expiresInHours: nil, maxUses: 5)).expiresAt == nil)
        #expect(throws: (any Error).self) { try GroupsValidation.invite(CreateGroupInviteRequest(expiresInHours: 0, maxUses: nil)) }
        #expect(throws: (any Error).self) { try GroupsValidation.invite(CreateGroupInviteRequest(expiresInHours: 721, maxUses: nil)) }
        #expect(throws: (any Error).self) { try GroupsValidation.invite(CreateGroupInviteRequest(expiresInHours: 1, maxUses: 0)) }
    }

    @Test("The filter catches disguised slurs without hitting innocent words")
    func contentFilter() {
        #expect(!GroupsContentFilter.isAllowed("you f4gg0t"))
        #expect(!GroupsContentFilter.isAllowed("N1GGGG3R!!"))
        #expect(!GroupsContentFilter.isAllowed("Wéťback"))
        #expect(GroupsContentFilter.isAllowed("Niger's bond yields"))
        #expect(GroupsContentFilter.isAllowed("Scunthorpe United"))
        #expect(GroupsContentFilter.isAllowed("pros and cons of $AAPL"))
        #expect(GroupsContentFilter.isAllowed("buy the dip"))
        #expect(!GroupsContentFilter.isAllowed("total scam coin", extraTerms: ["scam coin"]))
        #expect(GroupsContentFilter.isAllowed("scam", extraTerms: ["scam coin"]))
    }
}

/// Groups against a real database: creation, membership, channels, messages,
/// invites, moderation and the flag.
@Suite("Groups routes", .serialized)
struct GroupsRouteTests {
    private func withApp(groups: Bool = true, publicDirectory: Bool = true, _ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            setenv("NORVIQ_ADMIN_USER_IDS", "", 1)
            setenv("SOCIAL_ENABLED", "1", 1)
            setenv("GROUPS_ENABLED", groups ? "1" : "0", 1)
            setenv("GROUPS_PUBLIC_ENABLED", publicDirectory ? "1" : "0", 1)
            defer {
                for key in ["NORVIQ_ADMIN_USER_IDS", "SOCIAL_ENABLED", "GROUPS_ENABLED", "GROUPS_PUBLIC_ENABLED"] {
                    unsetenv(key)
                }
            }
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    // MARK: - Helpers

    private struct Reply {
        let status: HTTPStatus
        let body: Data

        func decode<T: Decodable>(_: T.Type) throws -> T {
            try JSONDecoder.backendAPI.decode(T.self, from: body)
        }

        var code: String? {
            try? decode(APIErrorEnvelope.self).code
        }
    }

    private func register(_ app: Application, _ id: String, guidelines: Bool = true) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "grp_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "grp+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var response: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })
        let auth = try #require(response)
        if id == "admin" {
            setenv("NORVIQ_ADMIN_USER_IDS", auth.userId.uuidString, 1)
        }
        if guidelines {
            #expect(try await send(app, .POST, "v1/community/guidelines/accept", as: auth).status == .noContent)
        }
        return auth
    }

    private func send(
        _ app: Application,
        _ method: HTTPMethod,
        _ path: String,
        as auth: AuthResponse,
        body: (any Content)? = nil
    ) async throws -> Reply {
        var reply: Reply?
        try await app.testing().test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: auth.token)
            if let body {
                try req.content.encode(body)
            }
        }, afterResponse: { res async throws in
            reply = Reply(status: res.status, body: Data(res.body.readableBytesView))
        })
        return try #require(reply)
    }

    private func create(
        _ app: Application,
        as auth: AuthResponse,
        name: String = "$AAPL holders",
        topic: GroupTopic = .stock,
        ticker: String? = "AAPL",
        visibility: GroupVisibility = .private
    ) async throws -> GroupDetail {
        let reply = try await send(app, .POST, "v1/groups", as: auth, body: CreateGroupRequest(
            name: name, description: nil, iconEmoji: "🍎", topic: topic, ticker: ticker, visibility: visibility
        ))
        #expect(reply.status == .ok)
        return try reply.decode(GroupDetail.self)
    }

    private func post(_ app: Application, _ channelId: UUID, as auth: AuthResponse, _ body: String, id: String = UUID().uuidString) async throws -> Reply {
        try await send(app, .POST, "v1/group-channels/\(channelId)/messages", as: auth, body: SendGroupMessageRequest(clientMessageId: id, body: body))
    }

    private func inviteLink(_ app: Application, _ groupId: UUID, as auth: AuthResponse, maxUses: Int? = nil) async throws -> GroupInviteLink {
        let reply = try await send(app, .POST, "v1/groups/\(groupId)/invites", as: auth, body: CreateGroupInviteRequest(expiresInHours: 24, maxUses: maxUses))
        #expect(reply.status == .ok)
        return try reply.decode(GroupInviteLink.self)
    }

    private func join(_ app: Application, _ groupId: UUID, as auth: AuthResponse, creator: AuthResponse) async throws {
        let link = try await inviteLink(app, groupId, as: creator)
        #expect(try await send(app, .POST, "v1/group-invites/\(link.code)/redeem", as: auth).status == .ok)
    }

    // MARK: - Flag and gate

    @Test("Off by default: every route is a 404")
    func flagOff() async throws {
        try await withApp(groups: false) { app in
            let ana = try await register(app, "off")
            #expect(try await send(app, .GET, "v1/groups", as: ana).status == .notFound)
            let config = try await send(app, .GET, "v1/social/config", as: ana)
            #expect(String(decoding: config.body, as: UTF8.self).contains("\"groups\":false"))
        }
    }

    @Test("Creating needs a username and accepted guidelines; config advertises groups")
    func contributionGate() async throws {
        try await withApp { app in
            let ana = try await register(app, "gate", guidelines: false)
            let reply = try await send(app, .POST, "v1/groups", as: ana, body: CreateGroupRequest(
                name: "Club", description: nil, iconEmoji: nil, topic: .community, ticker: nil, visibility: .private
            ))
            #expect(reply.status == .forbidden)
            #expect(reply.code == "guidelines_required")
            let config = try await send(app, .GET, "v1/social/config", as: ana)
            #expect(String(decoding: config.body, as: UTF8.self).contains("\"groups\":true"))
        }
    }

    // MARK: - Groups

    @Test("Create makes #general and the owner; private groups 404 to outsiders")
    func createAndPrivacy() async throws {
        try await withApp { app in
            let ana = try await register(app, "ana")
            let bo = try await register(app, "bo")
            let detail = try await create(app, as: ana)
            #expect(detail.channels.map(\.name) == ["general"])
            #expect(detail.group.membership?.role == .owner)
            #expect(detail.group.ticker == "AAPL")
            #expect(detail.permissions.canManageChannels)
            #expect(detail.group.defaultChannelId == detail.channels.first?.id)

            let outsider = try await send(app, .GET, "v1/groups/\(detail.group.id)", as: bo)
            #expect(outsider.status == .notFound)
            #expect(outsider.code == "group_not_found")
            #expect(try await send(app, .GET, "v1/group-channels/\(detail.channels[0].id)/messages", as: bo).status == .notFound)

            let mine = try await send(app, .GET, "v1/groups", as: ana).decode(GroupListResponse.self)
            #expect(mine.items.map(\.id) == [detail.group.id])
        }
    }

    @Test("Three groups a day")
    func dailyCap() async throws {
        try await withApp { app in
            let ana = try await register(app, "cap")
            for index in 0 ..< 3 {
                _ = try await create(app, as: ana, name: "Group \(index)")
            }
            let reply = try await send(app, .POST, "v1/groups", as: ana, body: CreateGroupRequest(
                name: "One more", description: nil, iconEmoji: nil, topic: .custom, ticker: nil, visibility: .private
            ))
            #expect(reply.status == .tooManyRequests)
            #expect(reply.code == "group_create_limit")
        }
    }

    @Test("Public groups: directory by ticker, preview, join; the switch hides them")
    func publicGroups() async throws {
        try await withApp { app in
            let ana = try await register(app, "pub")
            let bo = try await register(app, "pubbo")
            let group = try await create(app, as: ana, name: "Nvidia bulls", ticker: "$nvda", visibility: .public)
            _ = try await create(app, as: ana, name: "Apple", visibility: .public)

            let found = try await send(app, .GET, "v1/groups/discover?ticker=nvda", as: bo).decode(GroupDirectoryPage.self)
            #expect(found.items.map(\.id) == [group.group.id])
            let byName = try await send(app, .GET, "v1/groups/discover?q=bull", as: bo).decode(GroupDirectoryPage.self)
            #expect(byName.items.map(\.id) == [group.group.id])
            let suggested = try await send(app, .GET, "v1/groups/discover?tickers=MSFT,NVDA", as: bo).decode(GroupDirectoryPage.self)
            #expect(suggested.items.count == 1)

            let preview = try await send(app, .GET, "v1/groups/\(group.group.id)", as: bo).decode(GroupDetail.self)
            #expect(preview.channels.isEmpty)
            #expect(preview.permissions == .none)
            #expect(preview.group.membership == nil)
            let blockedRead = try await send(app, .GET, "v1/group-channels/\(group.channels[0].id)/messages", as: bo)
            #expect(blockedRead.code == "group_membership_required")

            let joined = try await send(app, .POST, "v1/groups/\(group.group.id)/join", as: bo).decode(GroupDetail.self)
            #expect(joined.group.membership?.role == .member)
            #expect(joined.group.membership?.pushEnabled == false)
            #expect(joined.group.memberCount == 2)
        }
        try await withApp(publicDirectory: false) { app in
            let ana = try await register(app, "nopub")
            #expect(try await send(app, .GET, "v1/groups/discover", as: ana).status == .notFound)
            let reply = try await send(app, .POST, "v1/groups", as: ana, body: CreateGroupRequest(
                name: "Open", description: nil, iconEmoji: nil, topic: .community, ticker: nil, visibility: .public
            ))
            #expect(reply.status == .badRequest)
        }
    }

    // MARK: - Messages

    @Test("Messages get consecutive seqs, dedupe by clientMessageId, and page both ways")
    func messages() async throws {
        try await withApp { app in
            let ana = try await register(app, "msg")
            let bo = try await register(app, "msgbo")
            let group = try await create(app, as: ana)
            let channel = group.channels[0].id
            try await join(app, group.group.id, as: bo, creator: ana)

            let first = try await post(app, channel, as: ana, "hello", id: "c-1")
            #expect(first.status == .created)
            let again = try await post(app, channel, as: ana, "hello", id: "c-1")
            #expect(again.status == .ok)
            #expect(try again.decode(GroupMessage.self).id == first.decode(GroupMessage.self).id)
            for index in 2 ... 5 {
                #expect(try await post(app, channel, as: bo, "m\(index)").status == .created)
            }

            let latest = try await send(app, .GET, "v1/group-channels/\(channel)/messages?limit=2", as: ana).decode(GroupMessagePage.self)
            #expect(latest.items.map(\.seq) == [4, 5])
            #expect(latest.hasMoreBefore)
            #expect(!latest.hasMoreAfter)
            let older = try await send(app, .GET, "v1/group-channels/\(channel)/messages?before=4&limit=2", as: ana).decode(GroupMessagePage.self)
            #expect(older.items.map(\.seq) == [2, 3])
            #expect(older.hasMoreBefore)
            #expect(older.hasMoreAfter)
            let catchUp = try await send(app, .GET, "v1/group-channels/\(channel)/messages?after=3", as: ana).decode(GroupMessagePage.self)
            #expect(catchUp.items.map(\.seq) == [4, 5])
            #expect(!catchUp.hasMoreAfter)

            // Ana's own message never counts; Bo's four do.
            let unread = try await send(app, .GET, "v1/groups/unread-count", as: ana).decode(GroupUnreadCount.self)
            #expect(unread.total == 4)
            #expect(try await send(app, .POST, "v1/group-channels/\(channel)/read", as: ana, body: MarkGroupChannelReadRequest(seq: 5)).status == .noContent)
            #expect(try await send(app, .POST, "v1/group-channels/\(channel)/read", as: ana, body: MarkGroupChannelReadRequest(seq: 2)).status == .noContent)
            let after = try await send(app, .GET, "v1/groups/unread-count", as: ana).decode(GroupUnreadCount.self)
            #expect(after.total == 0)

            let filtered = try await post(app, channel, as: bo, "you faggot")
            #expect(filtered.status == .unprocessableEntity)
            #expect(filtered.code == "content_rejected")
            #expect(try await post(app, channel, as: bo, String(repeating: "x", count: 2001)).status == .badRequest)
        }
    }

    @Test("Joining never shows old history as unread")
    func joinMarksRead() async throws {
        try await withApp { app in
            let ana = try await register(app, "hist")
            let bo = try await register(app, "histbo")
            let group = try await create(app, as: ana)
            for index in 0 ..< 3 {
                _ = try await post(app, group.channels[0].id, as: ana, "old \(index)")
            }
            try await join(app, group.group.id, as: bo, creator: ana)
            let unread = try await send(app, .GET, "v1/groups/unread-count", as: bo).decode(GroupUnreadCount.self)
            #expect(unread.total == 0)
        }
    }

    @Test("Delete permissions: author and admins yes, other members no; tombstones keep the slot")
    func deletePermissions() async throws {
        try await withApp { app in
            let ana = try await register(app, "del")
            let bo = try await register(app, "delbo")
            let cy = try await register(app, "delcy")
            let group = try await create(app, as: ana)
            let channel = group.channels[0].id
            try await join(app, group.group.id, as: bo, creator: ana)
            try await join(app, group.group.id, as: cy, creator: ana)

            let message = try await post(app, channel, as: bo, "mine").decode(GroupMessage.self)
            #expect(try await send(app, .DELETE, "v1/group-messages/\(message.id)", as: cy).code == "group_forbidden")
            #expect(try await send(app, .DELETE, "v1/group-messages/\(message.id)", as: ana).status == .noContent)
            let page = try await send(app, .GET, "v1/group-channels/\(channel)/messages", as: cy).decode(GroupMessagePage.self)
            #expect(page.items.first?.isDeleted == true)
            #expect(page.items.first?.body == nil)
        }
    }

    @Test("Blocked authors disappear from the channel and from unread")
    func blocking() async throws {
        try await withApp { app in
            let ana = try await register(app, "blk")
            let bo = try await register(app, "blkbo")
            let group = try await create(app, as: ana)
            try await join(app, group.group.id, as: bo, creator: ana)
            _ = try await post(app, group.channels[0].id, as: bo, "hi ana")
            #expect(try await send(app, .POST, "v1/community/blocks", as: ana, body: UserBlockRequest(username: "grp_blkbo")).status == .noContent)
            let page = try await send(app, .GET, "v1/group-channels/\(group.channels[0].id)/messages", as: ana).decode(GroupMessagePage.self)
            #expect(page.items.isEmpty)
            #expect(try await send(app, .GET, "v1/groups/unread-count", as: ana).decode(GroupUnreadCount.self).total == 0)
        }
    }

    // MARK: - Invites

    @Test("Links: max uses, expiry and revocation; a member re-redeeming is a no-op")
    func inviteLinks() async throws {
        try await withApp { app in
            let ana = try await register(app, "inv")
            let bo = try await register(app, "invbo")
            let cy = try await register(app, "invcy")
            let group = try await create(app, as: ana)
            let link = try await inviteLink(app, group.group.id, as: ana, maxUses: 1)
            #expect(link.url.hasSuffix("/g/\(link.code)"))

            let preview = try await send(app, .GET, "v1/group-invites/\(link.code)", as: bo).decode(GroupInvitePreview.self)
            #expect(preview.group.name == "$AAPL holders")
            #expect(preview.inviterUsername == "grp_inv")
            #expect(!preview.alreadyMember)

            #expect(try await send(app, .POST, "v1/group-invites/\(link.code)/redeem", as: bo).status == .ok)
            #expect(try await send(app, .POST, "v1/group-invites/\(link.code)/redeem", as: bo).status == .ok)
            let spent = try await send(app, .POST, "v1/group-invites/\(link.code)/redeem", as: cy)
            #expect(spent.status == .gone)
            #expect(spent.code == "invite_exhausted")

            let revoked = try await inviteLink(app, group.group.id, as: ana)
            #expect(try await send(app, .DELETE, "v1/group-invites/\(revoked.id)", as: ana).status == .noContent)
            #expect(try await send(app, .GET, "v1/group-invites/\(revoked.code)", as: cy).status == .notFound)

            let expired = try await inviteLink(app, group.group.id, as: ana)
            let record = try #require(try await GroupInviteRecord.find(expired.id, on: app.db))
            record.expiresAt = Date().addingTimeInterval(-60)
            try await record.save(on: app.db)
            #expect(try await send(app, .GET, "v1/group-invites/\(expired.code)", as: cy).code == "invite_expired")
        }
    }

    @Test("Two redeems racing for the last use: one gets in")
    func concurrentRedeem() async throws {
        try await withApp { app in
            let ana = try await register(app, "race")
            let bo = try await register(app, "racebo")
            let cy = try await register(app, "racecy")
            let group = try await create(app, as: ana)
            let link = try await inviteLink(app, group.group.id, as: ana, maxUses: 1)
            async let first = send(app, .POST, "v1/group-invites/\(link.code)/redeem", as: bo)
            async let second = send(app, .POST, "v1/group-invites/\(link.code)/redeem", as: cy)
            let statuses = try await [first.status, second.status]
            #expect(statuses.filter { $0 == .ok }.count == 1)
            #expect(statuses.contains(.gone))
            let detail = try await send(app, .GET, "v1/groups/\(group.group.id)", as: ana).decode(GroupDetail.self)
            #expect(detail.group.memberCount == 2)
        }
    }

    @Test("Direct invitations reach friends only; accepting joins")
    func directInvitations() async throws {
        try await withApp { app in
            let ana = try await register(app, "dir")
            let bo = try await register(app, "dirbo")
            let cy = try await register(app, "dircy")
            try await SocialService.befriend(ana.userId, bo.userId, on: app.db)
            let group = try await create(app, as: ana)

            let response = try await send(
                app, .POST, "v1/groups/\(group.group.id)/invitations", as: ana,
                body: GroupDirectInvitationRequest(userIds: [bo.userId, cy.userId])
            ).decode(GroupDirectInvitationResponse.self)
            #expect(response.invitedUserIds == [bo.userId])

            let pending = try await send(app, .GET, "v1/groups/invitations", as: bo).decode(GroupInvitationList.self)
            #expect(pending.items.map(\.group.id) == [group.group.id])
            #expect(try await send(app, .GET, "v1/groups/unread-count", as: bo).decode(GroupUnreadCount.self).pendingInvitationCount == 1)
            let joined = try await send(app, .POST, "v1/groups/invitations/\(pending.items[0].id)/accept", as: bo)
            #expect(joined.status == .ok)
            #expect(try joined.decode(GroupDetail.self).group.membership?.role == .member)
            #expect(try await send(app, .GET, "v1/groups/invitations", as: cy).decode(GroupInvitationList.self).items.isEmpty)
        }
    }

    // MARK: - Moderation

    @Test("Roles: kick needs a higher rank, a ban stops rejoining, ownership transfers")
    func moderation() async throws {
        try await withApp { app in
            let ana = try await register(app, "mod")
            let bo = try await register(app, "modbo")
            let cy = try await register(app, "modcy")
            let group = try await create(app, as: ana)
            let id = group.group.id
            try await join(app, id, as: bo, creator: ana)
            try await join(app, id, as: cy, creator: ana)

            #expect(try await send(app, .DELETE, "v1/groups/\(id)/members/\(cy.userId)", as: bo).code == "group_forbidden")
            #expect(try await send(app, .PATCH, "v1/groups/\(id)/members/\(bo.userId)", as: ana, body: UpdateGroupMemberRequest(role: .admin)).status == .noContent)
            #expect(try await send(app, .DELETE, "v1/groups/\(id)/members/\(ana.userId)", as: bo).code == "group_forbidden")
            #expect(try await send(app, .POST, "v1/groups/\(id)/bans", as: bo, body: GroupBanRequest(userId: cy.userId, reason: "spam")).status == .noContent)

            let rejoin = try await inviteLink(app, id, as: ana)
            let refused = try await send(app, .POST, "v1/group-invites/\(rejoin.code)/redeem", as: cy)
            #expect(refused.code == "group_banned")

            #expect(try await send(app, .POST, "v1/groups/\(id)/leave", as: ana).code == "owner_must_transfer")
            #expect(try await send(app, .POST, "v1/groups/\(id)/transfer", as: ana, body: TransferGroupOwnershipRequest(userId: bo.userId)).status == .noContent)
            let detail = try await send(app, .GET, "v1/groups/\(id)", as: ana).decode(GroupDetail.self)
            #expect(detail.ownerUsername == "grp_modbo")
            #expect(detail.group.membership?.role == .admin)
            #expect(try await send(app, .POST, "v1/groups/\(id)/leave", as: ana).status == .noContent)
        }
    }

    @Test("Channels: limit-free create, unique names, never delete the last one")
    func channels() async throws {
        try await withApp { app in
            let ana = try await register(app, "chn")
            let bo = try await register(app, "chnbo")
            let group = try await create(app, as: ana)
            let id = group.group.id
            try await join(app, id, as: bo, creator: ana)

            let created = try await send(app, .POST, "v1/groups/\(id)/channels", as: ana, body: CreateGroupChannelRequest(name: "Earnings Talk", topic: "Q3"))
            #expect(try created.decode(GroupChannel.self).name == "earnings-talk")
            #expect(try await send(app, .POST, "v1/groups/\(id)/channels", as: ana, body: CreateGroupChannelRequest(name: "earnings-talk", topic: nil)).code == "channel_name_taken")
            #expect(try await send(app, .POST, "v1/groups/\(id)/channels", as: bo, body: CreateGroupChannelRequest(name: "mine", topic: nil)).code == "group_forbidden")

            #expect(try await send(app, .DELETE, "v1/group-channels/\(group.channels[0].id)", as: ana).status == .noContent)
            let remaining = try created.decode(GroupChannel.self).id
            #expect(try await send(app, .DELETE, "v1/group-channels/\(remaining)", as: ana).code == "last_channel")
        }
    }

    @Test("A reported message reaches the admin queue, even after deletion")
    func reports() async throws {
        try await withApp { app in
            let admin = try await register(app, "admin")
            let ana = try await register(app, "rep")
            let bo = try await register(app, "repbo")
            let group = try await create(app, as: ana)
            try await join(app, group.group.id, as: bo, creator: ana)
            let message = try await post(app, group.channels[0].id, as: bo, "buy my course").decode(GroupMessage.self)

            let filed = try await send(app, .POST, "v1/group-messages/\(message.id)/report", as: ana, body: GroupMessageReportRequest(reason: .spam, note: nil))
            #expect(filed.status == .accepted)
            #expect(try await send(app, .DELETE, "v1/group-messages/\(message.id)", as: bo).status == .noContent)

            let queue = try await send(app, .GET, "v1/admin/community/reports", as: admin).decode(BoardReportListResponse.self)
            let item = try #require(queue.items.first { $0.groupMessageId == message.id })
            #expect(item.excerpt == "buy my course")
            #expect(item.groupName == "$AAPL holders")
            #expect(item.targetAuthorUsername == "grp_repbo")
        }
    }

    @Test("A global ban turns Groups away with the community code")
    func globalBan() async throws {
        try await withApp { app in
            let admin = try await register(app, "admin")
            let ana = try await register(app, "ban")
            #expect(try await send(
                app, .POST, "v1/admin/community/sanctions", as: admin,
                body: CreateSanctionRequest(username: "grp_ban", kind: .ban, reason: "Testing", durationHours: nil)
            ).status == .ok)
            let reply = try await send(app, .GET, "v1/groups", as: ana)
            #expect(reply.status == .forbidden)
            #expect(reply.code == "community_banned")
        }
    }
}
