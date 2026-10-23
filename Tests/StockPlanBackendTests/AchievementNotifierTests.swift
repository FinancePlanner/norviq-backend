import Fluent
import FluentSQL
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// Records social pushes and the devices they went to; every other kind is a no-op.
private final class AchievementPushRecorder: PushNotificationSending, @unchecked Sendable {
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

/// Unlock news: the `social_activity` row written with each live or sweep
/// unlock, and the one push per evaluation to devices that understand it.
@Suite("Achievement notifier", .serialized)
struct AchievementNotifierTests {
    private func withApp(_ test: (Application, AchievementPushRecorder) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            setenv("ACHIEVEMENTS_ENABLED", "1", 1)
            let previousDelay = AchievementHooks.delay
            AchievementHooks.delay = .milliseconds(50)
            // On a near-empty test database every user is a founding member;
            // switch that unlock off so counts are about what each test does.
            let previousFoundingLimit = AchievementMetrics.foundingLimit
            AchievementMetrics.foundingLimit = 0
            defer {
                AchievementMetrics.foundingLimit = previousFoundingLimit
                AchievementHooks.delay = previousDelay
                unsetenv("ACHIEVEMENTS_ENABLED")
            }
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                let recorder = AchievementPushRecorder()
                app.pushNotificationSender = recorder
                // Achievements went live long ago, so a freshly registered user is live.
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

    private func register(_ app: Application, _ id: String) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "achn_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "achn+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var response: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })
        // Anything registration queued has run before the test starts counting.
        await AchievementHooks.shared.waitUntilIdle()
        return try #require(response)
    }

    private func addDevice(_ app: Application, userId: UUID, token: String, capabilities: [String]) async throws {
        let json = try String(decoding: JSONEncoder().encode(capabilities), as: UTF8.self)
        try await PushDevice(
            userId: userId,
            deviceToken: token,
            platform: PushPlatform.ios.rawValue,
            apnsEnvironment: PushAPNSEnvironment.development.rawValue,
            authorizationStatus: PushAuthorizationStatus.authorized.rawValue,
            isActive: true,
            lastSeenAt: Date(),
            capabilitiesJSON: json
        ).save(on: app.db)
    }

    private func runHook(_ app: Application, userId: UUID) async {
        AchievementHooks.shared.schedule(userId, app: app)
        await AchievementHooks.shared.waitUntilIdle()
    }

    private func unlocks(_ app: Application, userId: UUID) async throws -> [UserAchievement] {
        try await UserAchievement.query(on: app.db).filter(\.$user.$id == userId).all()
    }

    private func activity(_ app: Application, userId: UUID) async throws -> [SocialActivity] {
        try await SocialActivity.query(on: app.db).filter(\.$actorId == userId).all()
    }

    @Test("A live unlock writes one activity row and pushes once to capable devices")
    func liveUnlockPushes() async throws {
        try await withApp { app, recorder in
            let user = try await register(app, "live")
            try await addDevice(app, userId: user.userId, token: "capable", capabilities: [AchievementNotifier.capability])
            try await addDevice(app, userId: user.userId, token: "old-app", capabilities: [])
            try await OnboardingLatches.latch(.holding, userId: user.userId, on: app.db)

            await runHook(app, userId: user.userId)

            let unlock = try #require(try await unlocks(app, userId: user.userId).first { $0.achievementKey == "start.first_holding" })
            #expect(unlock.source == AchievementSource.live.rawValue)
            #expect(unlock.notifiedAt != nil)

            let rows = try await activity(app, userId: user.userId)
            #expect(rows.count == 1)
            #expect(rows.first?.kind == "achievement_unlocked")
            #expect(rows.first?.userAchievementId == unlock.id)

            #expect(recorder.sent.count == 1)
            let sent = try #require(recorder.sent.first)
            #expect(sent.message.kind == .achievementUnlocked)
            #expect(sent.message.kind.rawValue == "achievement_unlocked")
            #expect(sent.message.title == "Achievement unlocked")
            #expect(sent.message.body == "First Holding")
            #expect(sent.message.threadID == "achievements")
            #expect(sent.deviceTokens == ["capable"])
        }
    }

    @Test("No push and no notified_at without a device that has the capability")
    func noCapableDeviceNoPush() async throws {
        try await withApp { app, recorder in
            let user = try await register(app, "nocap")
            try await addDevice(app, userId: user.userId, token: "old-app", capabilities: ["rebalancing_v1"])
            try await OnboardingLatches.latch(.holding, userId: user.userId, on: app.db)

            await runHook(app, userId: user.userId)

            let unlock = try #require(try await unlocks(app, userId: user.userId).first { $0.achievementKey == "start.first_holding" })
            #expect(unlock.notifiedAt == nil)
            #expect(try await activity(app, userId: user.userId).count == 1)
            #expect(recorder.sent.isEmpty)
        }
    }

    @Test("A backfill evaluation writes no activity and pushes nothing")
    func backfillIsSilent() async throws {
        try await withApp { app, recorder in
            let user = try await register(app, "backfill")
            try await AchievementEvaluation(userId: user.userId, needsBackfill: true).save(on: app.db)
            try await addDevice(app, userId: user.userId, token: "capable", capabilities: [AchievementNotifier.capability])
            try await OnboardingLatches.latch(.holding, userId: user.userId, on: app.db)

            await runHook(app, userId: user.userId)

            let rows = try await unlocks(app, userId: user.userId)
            #expect(rows.contains { $0.achievementKey == "start.first_holding" && $0.source == AchievementSource.backfill.rawValue })
            #expect(rows.allSatisfy { $0.notifiedAt == nil })
            #expect(try await activity(app, userId: user.userId).isEmpty)
            #expect(recorder.sent.isEmpty)
        }
    }

    @Test("A legacy badge dual-write writes no activity")
    func legacyIsSilent() async throws {
        try await withApp { app, recorder in
            let user = try await register(app, "legacy")
            try await addDevice(app, userId: user.userId, token: "capable", capabilities: [AchievementNotifier.capability])
            await AchievementService.recordLegacyBadge(
                userId: user.userId, badge: .firstPurchase, tier: .bronze, earnedAt: Date(), on: app.db
            )

            let rows = try await unlocks(app, userId: user.userId)
            #expect(rows.contains { $0.source == AchievementSource.legacyBadge.rawValue })
            #expect(try await activity(app, userId: user.userId).isEmpty)
            #expect(recorder.sent.isEmpty)
        }
    }

    @Test("Several unlocks in one evaluation are one push")
    func severalUnlocksOnePush() async throws {
        try await withApp { app, recorder in
            let user = try await register(app, "many")
            try await addDevice(app, userId: user.userId, token: "capable", capabilities: [AchievementNotifier.capability])
            for latch in [OnboardingLatch.holding, .budget, .goal] {
                try await OnboardingLatches.latch(latch, userId: user.userId, on: app.db)
            }

            await runHook(app, userId: user.userId)

            let rows = try await unlocks(app, userId: user.userId)
            #expect(rows.count == 3)
            #expect(rows.allSatisfy { $0.notifiedAt != nil })
            #expect(try await activity(app, userId: user.userId).count == 3)
            #expect(recorder.sent.count == 1)
            #expect(recorder.sent.first?.message.title == "Achievements unlocked")
            #expect(recorder.sent.first?.message.body == "3 achievements unlocked")
        }
    }

    @Test("Listing achievements evaluates and writes activity, but never pushes")
    func routeEvaluationDoesNotPush() async throws {
        try await withApp { app, recorder in
            let user = try await register(app, "route")
            try await addDevice(app, userId: user.userId, token: "capable", capabilities: [AchievementNotifier.capability])
            try await OnboardingLatches.latch(.holding, userId: user.userId, on: app.db)

            try await app.testing().test(.GET, "v1/achievements", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: user.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let unlock = try #require(try await unlocks(app, userId: user.userId).first { $0.achievementKey == "start.first_holding" })
            #expect(unlock.notifiedAt == nil)
            #expect(try await activity(app, userId: user.userId).count == 1)
            #expect(recorder.sent.isEmpty)
        }
    }

    @Test("A sweep unlock writes activity and pushes")
    func sweepUnlockPushes() async throws {
        try await withApp { app, recorder in
            let user = try await register(app, "sweep")
            try await addDevice(app, userId: user.userId, token: "capable", capabilities: [AchievementNotifier.capability])
            try await OnboardingLatches.latch(.holding, userId: user.userId, on: app.db)

            await AchievementSweepJob(batchSize: 1000).runOnce(app)

            let unlock = try #require(try await unlocks(app, userId: user.userId).first { $0.achievementKey == "start.first_holding" })
            #expect(unlock.source == AchievementSource.sweep.rawValue)
            #expect(unlock.notifiedAt != nil)
            #expect(try await activity(app, userId: user.userId).count == 1)
            #expect(recorder.sent.count == 1)
            #expect(recorder.sent.first?.message.kind == .achievementUnlocked)
        }
    }

    @Test("Copy: tiered unlocks name their tier, hidden ones their real title")
    func copy() throws {
        let userId = UUID()
        let tiered = UserAchievement(userId: userId, achievementKey: "discipline.check_in", tier: "silver", source: .live)
        let message = try #require(AchievementNotifier.message(for: [tiered]))
        #expect(message.title == "Achievement unlocked")
        #expect(message.body == "Showing Up (Silver)")

        let hidden = try #require(AchievementCatalogue.all.first { $0.isHidden })
        let hiddenUnlock = UserAchievement(
            userId: userId, achievementKey: hidden.key, tier: hidden.tiers[0].tier, source: .live
        )
        let hiddenTitle = try #require(hidden.copy[.en]?.title)
        let hiddenMessage = try #require(AchievementNotifier.message(for: [hiddenUnlock]))
        #expect(hiddenMessage.body.hasPrefix(hiddenTitle))

        #expect(AchievementNotifier.message(for: []) == nil)
        #expect(AchievementNotifier.message(for: [tiered, hiddenUnlock])?.body == "2 achievements unlocked")
        #expect(SocialPushMessage.Kind.achievementCongrats.rawValue == "achievement_congrats")
    }
}
