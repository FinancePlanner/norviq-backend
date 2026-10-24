import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// Records social pushes and the devices they went to; every other kind is a no-op.
private final class FeedPushRecorder: PushNotificationSending, @unchecked Sendable {
    struct Sent {
        let message: SocialPushMessage
        let deviceTokens: [String]
    }

    private let lock = NSLock()
    private var _sent: [Sent] = []
    var sent: [Sent] {
        lock.withLock { _sent }
    }

    func sendSocialEvent(message: SocialPushMessage, devices: [PushDevice], req _: Request) async -> TargetPushSendSummary {
        lock.withLock { _sent.append(Sent(message: message, deviceTokens: devices.map(\.deviceToken))) }
        return .init(delivered: devices.count, failed: 0)
    }

    func sendTargetHit(target _: Target, currentPrice _: Double, devices _: [PushDevice], req _: Request) async -> TargetPushSendSummary {
        .init(delivered: 0, failed: 0)
    }

    func sendBudgetAlert(snapshot _: BudgetSnapshot, threshold _: Int, remainingAmount _: Double, devices _: [PushDevice], req _: Request) async -> TargetPushSendSummary {
        .init(delivered: 0, failed: 0)
    }

    func sendEarningsReminder(symbol _: String, earningsDate _: String, leadDays _: Int, devices _: [PushDevice], req _: Request) async -> TargetPushSendSummary {
        .init(delivered: 0, failed: 0)
    }

    func sendTaxOpportunity(opportunity _: TaxOpportunityResponse, devices _: [PushDevice], req _: Request) async -> TargetPushSendSummary {
        .init(delivered: 0, failed: 0)
    }

    func sendAutomationAlert(message _: AutomationPushMessage, devices _: [PushDevice], req _: Request) async -> TargetPushSendSummary {
        .init(delivered: 0, failed: 0)
    }

    func sendRebalancingDrift(alert _: RebalancingAlert, portfolioName _: String, devices _: [PushDevice], req _: Request) async -> TargetPushSendSummary {
        .init(delivered: 0, failed: 0)
    }
}

/// The friends' activity feed and congrats, through the real routes.
@Suite("Social feed", .serialized)
struct SocialFeedTests {
    private static let plainKey = "start.first_holding"
    private static let performanceKey = "perf.positive_year"

    private func withApp(feed: Bool = true, _ test: (Application, FeedPushRecorder) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            setenv("SOCIAL_ENABLED", "1", 1)
            setenv("SOCIAL_CONTACT_PEPPER", "test-pepper", 1)
            setenv("SOCIAL_INVITE_BASE_URL", "https://norviq.test", 1)
            setenv("ACHIEVEMENTS_ENABLED", "1", 1)
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
                let recorder = FeedPushRecorder()
                app.pushNotificationSender = recorder
                try await AchievementService.ensureActivated(at: Date(timeIntervalSince1970: 0), on: app.db)
                try await test(app, recorder)
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
            username: "sfd_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "sfd+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
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
        _ app: Application, _ method: HTTPMethod, _ path: String, as auth: AuthResponse, body: (any Content)? = nil
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

    /// Friends since 30 days ago, so older activity predates the friendship
    /// and recent activity does not.
    private func befriend(_ app: Application, _ a: AuthResponse, _ b: AuthResponse) async throws {
        let request = try await send(app, .POST, "v1/social/friend-requests", as: a, body: SocialSendFriendRequestBody(userId: b.userId))
        #expect(request.status == .ok)
        let id = try request.decode(SocialFriendRequestDTO.self).id
        #expect(try await send(app, .POST, "v1/social/friend-requests/\(id)/accept", as: b).status == .noContent)
        await AchievementHooks.shared.waitUntilIdle()
        try await setFriendshipDate(app, daysAgo: 30)
    }

    private func setFriendshipDate(_ app: Application, daysAgo: Double) async throws {
        for row in try await SocialFriendship.query(on: app.db).all() {
            row.createdAt = Date().addingTimeInterval(-daysAgo * 86400)
            try await row.save(on: app.db)
        }
    }

    /// Drops the unlocks and activity the hooks wrote for these users.
    private func clean(_ app: Application, _ users: [AuthResponse]) async throws {
        await AchievementHooks.shared.waitUntilIdle()
        let ids = users.map(\.userId)
        try await SocialActivity.query(on: app.db).filter(\.$actorId ~~ ids).delete()
        try await UserAchievement.query(on: app.db).filter(\.$user.$id ~~ ids).delete()
    }

    @discardableResult
    private func activity(
        _ app: Application, _ actor: AuthResponse, key: String = SocialFeedTests.plainKey, daysAgo: Double = 1
    ) async throws -> SocialActivity {
        let at = Date().addingTimeInterval(-daysAgo * 86400)
        let tier = AchievementCatalogue.definition(key)?.tiers.first?.tier ?? ""
        let unlock = UserAchievement(userId: actor.userId, achievementKey: key, tier: tier, unlockedAt: at, source: .live)
        try await unlock.save(on: app.db)
        let item = try SocialActivity(actorId: actor.userId, kind: AchievementNotifier.activityKind, userAchievementId: #require(unlock.id), createdAt: at)
        try await item.save(on: app.db)
        return item
    }

    private func congratsCount(_ app: Application, _ activityId: UUID) async throws -> Int {
        try await SocialCongrats.query(on: app.db).filter(\.$activityId == activityId).count()
    }

    private func feed(_ app: Application, as viewer: AuthResponse, query: String = "") async throws -> SocialFeedResponseDTO {
        let reply = try await send(app, .GET, "v1/social/feed\(query)", as: viewer)
        #expect(reply.status == .ok)
        return try reply.decode(SocialFeedResponseDTO.self)
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

    private func addDevice(_ app: Application, userId: UUID, token: String, capabilities: [String]) async throws {
        let json = try String(decoding: JSONEncoder().encode(capabilities), as: UTF8.self)
        try await PushDevice(
            userId: userId, deviceToken: token, platform: PushPlatform.ios.rawValue,
            apnsEnvironment: PushAPNSEnvironment.development.rawValue,
            authorizationStatus: PushAuthorizationStatus.authorized.rawValue,
            isActive: true, lastSeenAt: Date(), capabilitiesJSON: json
        ).save(on: app.db)
    }

    // MARK: - Flag and config

    @Test("Feed off: feed, congrats and friend achievements all 404")
    func flagOff() async throws {
        try await withApp(feed: false) { app, _ in
            let a = try await register(app, "off1")
            let b = try await register(app, "off2")
            try await befriend(app, a, b)
            #expect(try await send(app, .GET, "v1/social/feed", as: a).status == .notFound)
            #expect(try await send(app, .POST, "v1/social/feed/\(UUID())/congrats", as: a).status == .notFound)
            #expect(try await send(app, .GET, "v1/social/users/\(b.userId)/achievements", as: a).status == .notFound)
            let config = try await send(app, .GET, "v1/social/config", as: a).decode(SocialConfigDTO.self)
            #expect(config.activityFeed == false)
        }
    }

    @Test("Feed on: the config DTO exposes activityFeed")
    func configExposesFeed() async throws {
        try await withApp { app, _ in
            let a = try await register(app, "cfg1")
            #expect(try await send(app, .GET, "v1/social/config", as: a).decode(SocialConfigDTO.self).activityFeed == true)
        }
    }

    // MARK: - Feed

    @Test("Friends' unlocks come newest first and page with a cursor")
    func newestFirstAndPaging() async throws {
        try await withApp { app, _ in
            let v = try await register(app, "pg1")
            let f = try await register(app, "pg2")
            try await befriend(app, v, f)
            try await clean(app, [v, f])
            let older = try await activity(app, f, daysAgo: 3)
            let newer = try await activity(app, f, key: "start.first_budget", daysAgo: 2)
            let page1 = try await feed(app, as: v, query: "?limit=1")
            #expect(page1.items.map(\.id) == [newer.id])
            #expect(page1.items.first?.actor.id == f.userId)
            #expect(page1.items.first?.achievement.key == "start.first_budget")
            #expect(page1.items.first?.congratsCount == 0)
            #expect(page1.items.first?.viewerCongratulated == false)
            let cursor = try #require(page1.nextCursor)
            let page2 = try await feed(app, as: v, query: "?limit=1&cursor=\(cursor)")
            #expect(page2.items.map(\.id) == [older.id])
            #expect(page2.nextCursor == nil)
        }
    }

    @Test("Excludes self, strangers, pre-friendship and old activity")
    func timeAndPeopleRules() async throws {
        try await withApp { app, _ in
            let v = try await register(app, "tr1")
            let f = try await register(app, "tr2")
            let stranger = try await register(app, "tr3")
            try await befriend(app, v, f)
            try await clean(app, [v, f, stranger])
            try await activity(app, v)
            try await activity(app, stranger)
            try await setFriendshipDate(app, daysAgo: 200)
            try await activity(app, f, key: "start.first_budget", daysAgo: 100) // older than 90 days
            let kept = try await activity(app, f, key: "start.first_goal", daysAgo: 10)
            let kept2 = try await activity(app, f, daysAgo: 80)
            #expect(try await feed(app, as: v).items.map(\.id) == [kept.id, kept2.id])
        }
    }

    @Test("Pre-friendship unlocks are hidden even inside 90 days")
    func beforeFriendship() async throws {
        try await withApp { app, _ in
            let v = try await register(app, "bf1")
            let f = try await register(app, "bf2")
            try await befriend(app, v, f) // friends since 30 days ago
            try await clean(app, [v, f])
            try await activity(app, f, daysAgo: 40)
            let after = try await activity(app, f, key: "start.first_budget", daysAgo: 5)
            #expect(try await feed(app, as: v).items.map(\.id) == [after.id])
        }
    }

    @Test("Hidden by showAchievements off, blocks either way and suspension")
    func privacyRules() async throws {
        try await withApp { app, _ in
            let v = try await register(app, "pr1")
            let off = try await register(app, "pr2")
            let blockedByMe = try await register(app, "pr3")
            let blocksMe = try await register(app, "pr4")
            let suspended = try await register(app, "pr5")
            let ok = try await register(app, "pr6")
            for other in [off, blockedByMe, blocksMe, suspended, ok] {
                try await befriend(app, v, other)
            }
            try await setPrivacy(app, as: off, ["showAchievements": false])
            try await setPrivacy(app, as: suspended, [:])
            try await clean(app, [v, off, blockedByMe, blocksMe, suspended, ok])
            for user in [off, blockedByMe, blocksMe, suspended] {
                try await activity(app, user)
            }
            let visible = try await activity(app, ok)
            try await SocialBlock(blockerId: v.userId, blockedId: blockedByMe.userId).save(on: app.db)
            try await SocialBlock(blockerId: blocksMe.userId, blockedId: v.userId).save(on: app.db)
            let record = try #require(try await SocialSettingsRecord.query(on: app.db).filter(\.$userId == suspended.userId).first())
            record.suspendedAt = Date()
            try await record.save(on: app.db)
            #expect(try await feed(app, as: v).items.map(\.id) == [visible.id])
        }
    }

    @Test("Performance achievements need the owner's showReturnPercent")
    func performanceGate() async throws {
        try await withApp { app, _ in
            let v = try await register(app, "pf1")
            let f = try await register(app, "pf2")
            try await befriend(app, v, f)
            try await clean(app, [v, f])
            let perf = try await activity(app, f, key: Self.performanceKey, daysAgo: 1)
            let plain = try await activity(app, f, daysAgo: 2)
            #expect(try await feed(app, as: v).items.map(\.id) == [plain.id])
            try await setPrivacy(app, as: f, ["showReturnPercent": true])
            #expect(try await feed(app, as: v).items.map(\.id) == [perf.id, plain.id])
        }
    }

    // MARK: - Congrats

    @Test("Congrats is idempotent: one row, count 1, viewerCongratulated")
    func congratsIdempotent() async throws {
        try await withApp { app, _ in
            let v = try await register(app, "cg1")
            let f = try await register(app, "cg2")
            try await befriend(app, v, f)
            try await clean(app, [v, f])
            let item = try await activity(app, f)
            let id = try #require(item.id)
            #expect(try await send(app, .POST, "v1/social/feed/\(id)/congrats", as: v).status == .noContent)
            #expect(try await send(app, .POST, "v1/social/feed/\(id)/congrats", as: v).status == .noContent)
            #expect(try await congratsCount(app, id) == 1)
            let first = try #require(try await feed(app, as: v).items.first)
            #expect(first.congratsCount == 1)
            #expect(first.viewerCongratulated == true)
        }
    }

    @Test("Own activity is 400; invisible or unknown activity is 404")
    func congratsGuards() async throws {
        try await withApp { app, _ in
            let v = try await register(app, "gd1")
            let f = try await register(app, "gd2")
            let stranger = try await register(app, "gd3")
            try await befriend(app, v, f)
            try await clean(app, [v, f, stranger])
            let own = try await activity(app, v)
            let strangers = try await activity(app, stranger)
            #expect(try await send(app, .POST, "v1/social/feed/\(#require(own.id))/congrats", as: v).status == .badRequest)
            #expect(try await send(app, .POST, "v1/social/feed/\(#require(strangers.id))/congrats", as: v).status == .notFound)
            #expect(try await send(app, .POST, "v1/social/feed/\(UUID())/congrats", as: v).status == .notFound)
            #expect(try await SocialCongrats.query(on: app.db).count() == 0)
        }
    }

    @Test("Push goes to capable devices of the actor, throttled to one per 10 minutes, never on a duplicate")
    func pushThrottle() async throws {
        try await withApp { app, recorder in
            let actor = try await register(app, "ps1")
            let a = try await register(app, "ps2")
            let b = try await register(app, "ps3")
            try await befriend(app, actor, a)
            try await befriend(app, actor, b)
            try await clean(app, [actor, a, b])
            try await addDevice(app, userId: actor.userId, token: "capable", capabilities: [AchievementNotifier.capability])
            try await addDevice(app, userId: actor.userId, token: "old-app", capabilities: [])
            let item = try await activity(app, actor, key: "social.inviter")
            let id = try #require(item.id)
            #expect(try await send(app, .POST, "v1/social/feed/\(id)/congrats", as: a).status == .noContent)
            let sent = recorder.sent
            #expect(sent.count == 1)
            #expect(sent.first?.message.kind == .achievementCongrats)
            #expect(sent.first?.message.title == "🎉 Congrats")
            #expect(sent.first?.message.body == "sfd_ps2 cheered your \(AchievementCatalogue.definition("social.inviter")?.copy[.en]?.title ?? "?") (Bronze)")
            #expect(sent.first?.deviceTokens == ["capable"])
            // Duplicate: no push.
            #expect(try await send(app, .POST, "v1/social/feed/\(id)/congrats", as: a).status == .noContent)
            #expect(recorder.sent.count == 1)
            // Another friend a moment later: throttled.
            #expect(try await send(app, .POST, "v1/social/feed/\(id)/congrats", as: b).status == .noContent)
            #expect(recorder.sent.count == 1)
            #expect(try await congratsCount(app, id) == 2)
        }
    }

    @Test("A congrats older than 10 minutes does not throttle the next push")
    func pushAfterWindow() async throws {
        try await withApp { app, recorder in
            let actor = try await register(app, "pw1")
            let a = try await register(app, "pw2")
            let b = try await register(app, "pw3")
            try await befriend(app, actor, a)
            try await befriend(app, actor, b)
            try await clean(app, [actor, a, b])
            try await addDevice(app, userId: actor.userId, token: "capable", capabilities: [AchievementNotifier.capability])
            let item = try await activity(app, actor)
            let id = try #require(item.id)
            try await SocialCongrats(activityId: id, fromUserId: a.userId, createdAt: Date().addingTimeInterval(-11 * 60)).save(on: app.db)
            #expect(try await send(app, .POST, "v1/social/feed/\(id)/congrats", as: b).status == .noContent)
            #expect(recorder.sent.count == 1)
        }
    }
}
