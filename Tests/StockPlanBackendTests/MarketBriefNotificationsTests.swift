import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// Records market brief pushes; every other kind is a no-op.
private final class BriefPushRecorder: PushNotificationSending, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [(message: MarketBriefPushMessage, devices: Int)] = []
    var sent: [(message: MarketBriefPushMessage, devices: Int)] {
        lock.withLock { _sent }
    }

    func sendMarketBrief(message: MarketBriefPushMessage, devices: [PushDevice], req _: Request) async -> TargetPushSendSummary {
        lock.withLock { _sent.append((message, devices.count)) }
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

@Suite("Market brief notifications", .serialized)
struct MarketBriefNotificationsTests {
    /// 2026-10-08 (a Thursday) at the given Lisbon wall-clock time.
    private func lisbon(_ hour: Int, _ minute: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MarketBriefSchedule.timeZone
        return try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: hour, minute: minute)))
    }

    private func registerUser(app: Application) async throws -> (id: UUID, token: String) {
        let id = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "briefpush_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "briefpush_\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            token = try res.content.decode(AuthResponse.self).token
        })
        return try await (app.jwt.keys.verify(token, as: SessionToken.self).userId, token)
    }

    private func optIn(_ app: Application, enabled: Bool, language: String) async throws -> UUID {
        let user = try await registerUser(app: app).id
        try await MarketBriefNotificationPreference(userId: user, enabled: enabled, language: language).save(on: app.db)
        try await PushDevice(
            userId: user, deviceToken: UUID().uuidString, platform: "ios",
            apnsEnvironment: "development", authorizationStatus: "authorized"
        ).save(on: app.db)
        return user
    }

    private func seedMorning(_ app: Application) async throws {
        try await app.marketBriefRepository.save(
            MarketBriefLanguage.allCases.map { MarketBriefFixtures.response(slot: .morning, language: $0.rawValue) },
            model: "m", generatedAt: Date(), on: app.db
        )
    }

    @Test("Message: title per slot and language, body is the first line, long lines are cut")
    func message() throws {
        let morning = try #require(MarketBriefPushMessage(brief: MarketBriefFixtures.response(slot: .morning, language: "pt-PT")))
        #expect(morning.title == "Briefing da manhã")
        #expect(morning.body == "Line for pt-PT.")
        #expect(morning.deepLink == "financeplan://market/brief?slot=morning&date=2026-10-08")

        let long = MarketBriefResponse(
            enabled: true, tradingDate: "2026-10-08", slot: .evening, language: "en", greeting: nil, groups: [],
            items: [MarketBriefItem(kind: .story, text: String(repeating: "a", count: 400), tickers: [], sourceUrl: nil)],
            generatedAt: nil, degraded: false
        )
        let evening = try #require(MarketBriefPushMessage(brief: long))
        #expect(evening.title == "Market close recap")
        #expect(evening.body.count == MarketBriefPushMessage.maxBodyLength)
        #expect(evening.body.hasSuffix("…"))

        #expect(MarketBriefPushMessage(brief: .empty(language: "en", enabled: true)) == nil)
    }

    @Test("Preferences: off by default, language normalised, scoped to the caller")
    func preferencesRoute() async throws {
        try await MarketBriefFixtures.withApp { app in
            let user = try await registerUser(app: app)
            let auth = { (req: inout TestingHTTPRequest) in
                req.headers.bearerAuthorization = BearerAuthorization(token: user.token)
            }
            try await app.testing().test(.GET, "v1/market/brief/notifications", beforeRequest: { auth(&$0) }) { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode(MarketBriefNotificationPreferences.self) == .init(enabled: false, language: "en"))
            }
            try await app.testing().test(.PUT, "v1/market/brief/notifications", beforeRequest: { req in
                auth(&req)
                try req.content.encode(MarketBriefNotificationPreferences(enabled: true, language: "pt"))
            }) { res async throws in
                #expect(try res.content.decode(MarketBriefNotificationPreferences.self) == .init(enabled: true, language: "pt-PT"))
            }
            try await app.testing().test(.GET, "v1/market/brief/notifications", beforeRequest: { auth(&$0) }) { res async throws in
                #expect(try res.content.decode(MarketBriefNotificationPreferences.self) == .init(enabled: true, language: "pt-PT"))
            }
            try await app.testing().test(.GET, "v1/market/brief/notifications") { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("Notifier: one push per language to opted-in users only")
    func fanOut() async throws {
        try await MarketBriefFixtures.withApp { app in
            let recorder = BriefPushRecorder()
            app.pushNotificationSender = recorder
            try await seedMorning(app)
            _ = try await optIn(app, enabled: true, language: "en")
            _ = try await optIn(app, enabled: true, language: "en")
            _ = try await optIn(app, enabled: true, language: "pt-PT")
            _ = try await optIn(app, enabled: false, language: "en")

            let req = Request(application: app, on: app.eventLoopGroup.next())
            let due = MarketBriefSchedule.Due(tradingDate: "2026-10-08", slot: .morning)
            let summary = try await MarketBriefNotifier(repository: app.marketBriefRepository)
                .notify(due, now: lisbon(8, 20), on: req)

            #expect(summary.delivered == 3)
            let byBody = Dictionary(uniqueKeysWithValues: recorder.sent.map { ($0.message.body, $0.devices) })
            #expect(byBody == ["Line for en.": 2, "Line for pt-PT.": 1])
        }
    }

    @Test("Notifier: a brief written long after its window opened is not pushed")
    func latePush() async throws {
        try await MarketBriefFixtures.withApp { app in
            let recorder = BriefPushRecorder()
            app.pushNotificationSender = recorder
            try await seedMorning(app)
            _ = try await optIn(app, enabled: true, language: "en")

            let req = Request(application: app, on: app.eventLoopGroup.next())
            let due = MarketBriefSchedule.Due(tradingDate: "2026-10-08", slot: .morning)
            let summary = try await MarketBriefNotifier(repository: app.marketBriefRepository)
                .notify(due, now: lisbon(10, 0), on: req)

            #expect(summary.delivered == 0)
            #expect(recorder.sent.isEmpty)
        }
    }

    @Test("Flag wiring: push is off by default")
    func pushFlagDefault() async throws {
        try await MarketBriefFixtures.withApp { app in
            #expect(app.marketBriefPushEnabled == false)
        }
    }
}
