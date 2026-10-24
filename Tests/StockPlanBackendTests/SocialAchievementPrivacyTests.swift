import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// The achievements privacy toggle, the profile showcase and the friend
/// achievements list, through the real routes.
@Suite("Social achievement privacy", .serialized)
struct SocialAchievementPrivacyTests {
    private func withApp(feed: Bool = true, achievements: Bool = true, _ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            setenv("SOCIAL_ENABLED", "1", 1)
            setenv("SOCIAL_CONTACT_PEPPER", "test-pepper", 1)
            setenv("SOCIAL_INVITE_BASE_URL", "https://norviq.test", 1)
            if achievements {
                setenv("ACHIEVEMENTS_ENABLED", "1", 1)
            }
            if feed {
                setenv("SOCIAL_ACTIVITY_FEED_ENABLED", "1", 1)
            }
            let previousDelay = AchievementHooks.delay
            AchievementHooks.delay = .zero
            let previousFounding = AchievementMetrics.foundingLimit
            AchievementMetrics.foundingLimit = 0
            defer {
                AchievementMetrics.foundingLimit = previousFounding
                AchievementHooks.delay = previousDelay
                for key in ["SOCIAL_ENABLED", "SOCIAL_CONTACT_PEPPER", "SOCIAL_INVITE_BASE_URL", "ACHIEVEMENTS_ENABLED", "SOCIAL_ACTIVITY_FEED_ENABLED"] {
                    unsetenv(key)
                }
            }
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await AchievementService.ensureActivated(at: Date(timeIntervalSince1970: 0), on: app.db)
                try await test(app)
                await AchievementHooks.shared.waitUntilIdle()
                try await app.autoRevert()
            } catch {
                await AchievementHooks.shared.waitUntilIdle()
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private struct Reply {
        let status: HTTPStatus
        let body: Data

        func decode<T: Decodable>(_: T.Type) throws -> T {
            try JSONDecoder.backendAPI.decode(T.self, from: body)
        }
    }

    private func register(_ app: Application, _ id: String) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "sap_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "sap+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var response: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })
        return try #require(response)
    }

    private func send(
        _ app: Application, _ method: HTTPMethod, _ path: String, as auth: AuthResponse,
        body: (any Content)? = nil, language: String? = nil
    ) async throws -> Reply {
        var reply: Reply?
        try await app.testing().test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: auth.token)
            if let language {
                req.headers.replaceOrAdd(name: .acceptLanguage, value: language)
            }
            if let body {
                try req.content.encode(body)
            }
        }, afterResponse: { res async throws in
            reply = Reply(status: res.status, body: Data(res.body.readableBytesView))
        })
        return try #require(reply)
    }

    private func befriend(_ app: Application, _ a: AuthResponse, _ b: AuthResponse) async throws {
        let request = try await send(app, .POST, "v1/social/friend-requests", as: a, body: SocialSendFriendRequestBody(userId: b.userId))
        #expect(request.status == .ok)
        let id = try request.decode(SocialFriendRequestDTO.self).id
        #expect(try await send(app, .POST, "v1/social/friend-requests/\(id)/accept", as: b).status == .noContent)
        await AchievementHooks.shared.waitUntilIdle()
    }

    private func setPrivacy(_ app: Application, as auth: AuthResponse, _ body: [String: Bool]) async throws {
        var full: [String: Any] = [
            "searchVisibility": "everyone", "discoverableByContacts": true, "discoverableByX": true,
            "showReturnPercent": false, "showStreaks": true, "showXP": true, "leaderboardOptIn": true,
        ]
        for (key, value) in body {
            full[key] = value
        }
        let data = try JSONSerialization.data(withJSONObject: full)
        var status: HTTPStatus = .internalServerError
        try await app.testing().test(.PUT, "v1/social/privacy", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: auth.token)
            req.headers.contentType = .json
            req.body = ByteBuffer(data: data)
        }, afterResponse: { res async throws in status = res.status })
        #expect(status == .ok)
    }

    /// Replaces whatever the user has unlocked with exactly these rows.
    @discardableResult
    private func seed(
        _ app: Application, _ userId: UUID, _ rows: [(key: String, tier: String, minutesAgo: Double, rank: Int?)]
    ) async throws -> [UserAchievement] {
        await AchievementHooks.shared.waitUntilIdle()
        try await UserAchievement.query(on: app.db).filter(\.$user.$id == userId).delete()
        var saved: [UserAchievement] = []
        for row in rows {
            let unlock = UserAchievement(
                userId: userId, achievementKey: row.key, tier: row.tier,
                unlockedAt: Date().addingTimeInterval(-row.minutesAgo * 60), source: .live
            )
            unlock.showcaseRank = row.rank
            try await unlock.save(on: app.db)
            saved.append(unlock)
        }
        return saved
    }

    private func plainKeys(_ count: Int) -> [String] {
        Array(AchievementCatalogue.all.filter { !$0.isPerformance && !$0.isHidden }.prefix(count).map(\.key))
    }

    private func profile(_ app: Application, of target: AuthResponse, as viewer: AuthResponse, language: String? = nil) async throws -> SocialProfileDTO {
        let reply = try await send(app, .GET, "v1/social/users/\(target.userId)", as: viewer, language: language)
        #expect(reply.status == .ok)
        return try reply.decode(SocialProfileDTO.self)
    }

    // MARK: - Privacy toggle

    @Test("An old client's PUT without showAchievements keeps the stored false")
    func oldClientKeepsValue() async throws {
        try await withApp { app in
            let a = try await register(app, "pv1")
            #expect(try await send(app, .GET, "v1/social/privacy", as: a).decode(SocialPrivacySettingsDTO.self).showAchievements == true)
            try await setPrivacy(app, as: a, ["showAchievements": false])
            // No showAchievements key at all.
            try await setPrivacy(app, as: a, ["showStreaks": false])
            let settings = try await send(app, .GET, "v1/social/privacy", as: a).decode(SocialPrivacySettingsDTO.self)
            #expect(settings.showAchievements == false)
            #expect(settings.showStreaks == false)
            try await setPrivacy(app, as: a, ["showAchievements": true])
            #expect(try await send(app, .GET, "v1/social/privacy", as: a).decode(SocialPrivacySettingsDTO.self).showAchievements == true)
        }
    }

    // MARK: - Profile

    @Test("A friend sees the badge count and the default showcase by tier, then recency")
    func defaultShowcase() async throws {
        try await withApp { app in
            let owner = try await register(app, "ds1")
            let friend = try await register(app, "ds2")
            try await befriend(app, owner, friend)
            let keys = plainKeys(5)
            try await seed(app, owner.userId, [
                (keys[0], "bronze", 1, nil), (keys[1], "gold", 50, nil), (keys[2], "silver", 20, nil),
                (keys[3], "bronze", 10, nil), (keys[4], "silver", 5, nil),
                ("legacy.firstExpense", "gold", 2, nil),
            ])
            let dto = try await profile(app, of: owner, as: friend)
            #expect(dto.badgeCount == 5)
            let shown = try #require(dto.showcase)
            #expect(shown.map(\.key) == [keys[1], keys[4], keys[2]])
            #expect(shown.map(\.tier) == ["gold", "silver", "silver"])
            #expect(shown.allSatisfy { !$0.title.isEmpty && !$0.iconKey.isEmpty })
        }
    }

    @Test("Pinned showcase order is respected and Accept-Language localizes titles")
    func pinnedShowcase() async throws {
        try await withApp { app in
            let owner = try await register(app, "pn1")
            let friend = try await register(app, "pn2")
            try await befriend(app, owner, friend)
            let keys = plainKeys(3)
            try await seed(app, owner.userId, [
                (keys[0], "gold", 1, 2), (keys[1], "bronze", 2, 1), (keys[2], "gold", 3, nil),
            ])
            let en = try await profile(app, of: owner, as: friend)
            #expect(en.showcase?.map(\.key) == [keys[1], keys[0]])
            let pt = try await profile(app, of: owner, as: friend, language: "pt-PT")
            #expect(pt.showcase?.map(\.key) == [keys[1], keys[0]])
            let definition = try #require(AchievementCatalogue.definition(keys[1]))
            #expect(en.showcase?.first?.title == definition.copy[.en]?.title)
            #expect(pt.showcase?.first?.title == definition.copy[.pt]?.title)
        }
    }

    @Test("Sharing off, non-friends and blocks hide badgeCount and showcase")
    func hiddenProfiles() async throws {
        try await withApp { app in
            let owner = try await register(app, "hp1")
            let friend = try await register(app, "hp2")
            let stranger = try await register(app, "hp3")
            let blocker = try await register(app, "hp4")
            try await befriend(app, owner, friend)
            try await befriend(app, owner, blocker)
            let keys = plainKeys(1)
            try await seed(app, owner.userId, [(keys[0], "gold", 1, nil)])

            #expect(try await profile(app, of: owner, as: friend).badgeCount == 1)
            let nonFriend = try await profile(app, of: owner, as: stranger)
            #expect(nonFriend.badgeCount == nil)
            #expect(nonFriend.showcase == nil)

            try await setPrivacy(app, as: owner, ["showAchievements": false])
            let off = try await profile(app, of: owner, as: friend)
            #expect(off.badgeCount == nil)
            #expect(off.showcase == nil)
            // Self always sees their own, whatever the toggle.
            #expect(try await profile(app, of: owner, as: owner).badgeCount == 1)

            try await setPrivacy(app, as: owner, ["showAchievements": true])
            #expect(try await send(app, .POST, "v1/social/blocks/\(owner.userId)", as: blocker).status == .noContent)
            #expect(try await send(app, .GET, "v1/social/users/\(owner.userId)", as: blocker).status == .notFound)
        }
    }

    @Test("With ACHIEVEMENTS_ENABLED off the profile carries no achievement fields")
    func flagOffProfile() async throws {
        try await withApp(feed: false, achievements: false) { app in
            let owner = try await register(app, "fo1")
            let friend = try await register(app, "fo2")
            try await befriend(app, owner, friend)
            try await seed(app, owner.userId, [(plainKeys(1)[0], "gold", 1, nil)])
            let dto = try await profile(app, of: owner, as: friend)
            #expect(dto.badgeCount == nil)
            #expect(dto.showcase == nil)
            let config = try await send(app, .GET, "v1/social/config", as: friend).decode(SocialConfigDTO.self)
            #expect(config.activityFeed == false)
        }
    }

    // MARK: - Friend achievements route

    @Test("The route lists a friend's unlocks newest first and 404s otherwise")
    func friendRoute() async throws {
        try await withApp { app in
            let owner = try await register(app, "fr1")
            let friend = try await register(app, "fr2")
            let stranger = try await register(app, "fr3")
            let blocker = try await register(app, "fr4")
            try await befriend(app, owner, friend)
            try await befriend(app, owner, blocker)
            let keys = plainKeys(3)
            try await seed(app, owner.userId, [
                (keys[0], "bronze", 30, nil), (keys[1], "silver", 5, nil), (keys[2], "gold", 15, nil),
                ("legacy.firstExpense", "gold", 1, nil),
            ])
            let path = "v1/social/users/\(owner.userId)/achievements"
            let listed = try await send(app, .GET, path, as: friend)
            #expect(listed.status == .ok)
            #expect(try listed.decode([AchievementUnlockDTO].self).map(\.key) == [keys[1], keys[2], keys[0]])
            #expect(try await send(app, .GET, path, as: owner).status == .ok)
            #expect(try await send(app, .GET, path, as: stranger).status == .notFound)

            // Blocked by the owner, and blocking the owner: both 404.
            #expect(try await send(app, .POST, "v1/social/blocks/\(owner.userId)", as: blocker).status == .noContent)
            #expect(try await send(app, .GET, path, as: blocker).status == .notFound)

            try await setPrivacy(app, as: owner, ["showAchievements": false])
            #expect(try await send(app, .GET, path, as: friend).status == .notFound)
            #expect(try await send(app, .GET, path, as: owner).status == .ok)
        }
    }

    @Test("A block set by the owner hides the list from the friend")
    func ownerBlocksViewer() async throws {
        try await withApp { app in
            let owner = try await register(app, "ob1")
            let friend = try await register(app, "ob2")
            try await befriend(app, owner, friend)
            try await seed(app, owner.userId, [(plainKeys(1)[0], "gold", 1, nil)])
            #expect(try await send(app, .POST, "v1/social/blocks/\(friend.userId)", as: owner).status == .noContent)
            #expect(try await send(app, .GET, "v1/social/users/\(owner.userId)/achievements", as: friend).status == .notFound)
        }
    }

    @Test("The route 404s with the feed flag off")
    func routeFlagOff() async throws {
        try await withApp(feed: false) { app in
            let owner = try await register(app, "rf1")
            let friend = try await register(app, "rf2")
            try await befriend(app, owner, friend)
            let config = try await send(app, .GET, "v1/social/config", as: friend).decode(SocialConfigDTO.self)
            #expect(config.achievements == true)
            #expect(config.activityFeed == false)
            #expect(try await send(app, .GET, "v1/social/users/\(owner.userId)/achievements", as: friend).status == .notFound)
        }
    }

    @Test("Performance unlocks stay hidden unless the owner shares return %")
    func performanceHidden() async throws {
        try await withApp { app in
            let owner = try await register(app, "pf1")
            let friend = try await register(app, "pf2")
            try await befriend(app, owner, friend)
            let plain = plainKeys(1)[0]
            let performance = try #require(AchievementCatalogue.all.first { $0.isPerformance }?.key)
            try await seed(app, owner.userId, [(plain, "bronze", 10, nil), (performance, "gold", 1, nil)])
            let path = "v1/social/users/\(owner.userId)/achievements"

            let hidden = try await profile(app, of: owner, as: friend)
            #expect(hidden.badgeCount == 1)
            #expect(hidden.showcase?.map(\.key) == [plain])
            #expect(try await send(app, .GET, path, as: friend).decode([AchievementUnlockDTO].self).map(\.key) == [plain])
            // The owner sees both.
            #expect(try await profile(app, of: owner, as: owner).badgeCount == 2)

            try await setPrivacy(app, as: owner, ["showReturnPercent": true])
            let shown = try await profile(app, of: owner, as: friend)
            #expect(shown.badgeCount == 2)
            #expect(shown.showcase?.first?.key == performance)
            #expect(try await send(app, .GET, path, as: friend).decode([AchievementUnlockDTO].self).map(\.key) == [performance, plain])
        }
    }

    // MARK: - Invite redemption (Task 2 review carry-over)

    @Test("Redeeming an invite between people who are already friends records no redemption")
    func alreadyFriendsRecordsNothing() async throws {
        try await withApp { app in
            let inviter = try await register(app, "iv1")
            let invitee = try await register(app, "iv2")
            let code = try await send(app, .POST, "v1/social/invites", as: inviter).decode(SocialInviteLinkDTO.self).code
            try await befriend(app, inviter, invitee)
            #expect(try await send(app, .POST, "v1/social/invites/\(code)/redeem", as: invitee).status == .ok)
            await AchievementHooks.shared.waitUntilIdle()
            #expect(try await SocialInviteRedemption.query(on: app.db).filter(\.$inviteeId == invitee.userId).count() == 0)
        }
    }
}
