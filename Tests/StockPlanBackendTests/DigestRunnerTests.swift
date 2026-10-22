import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

private actor DigestMailRecorder: MailerService {
    private var sent: [MailMessage] = []

    func send(_ message: MailMessage, on _: Request) async throws {
        sent.append(message)
    }

    func messages() -> [MailMessage] {
        sent
    }
}

/// Fixed closes for every symbol: 100 before the week, 110 inside it.
private struct FixedDigestSources: DigestDataSources {
    func dailyCloses(symbol _: String, from _: String, to _: String, on _: Request) async throws -> [DigestPriceBar] {
        [.init(date: "2026-10-16", close: 100), .init(date: "2026-10-23", close: 110)]
    }

    func earnings(from _: String, to _: String, on _: Request) async throws -> [EarningsItemResponse] {
        [EarningsItemResponse(date: "2026-10-28", hour: "amc", symbol: "AAPL")]
    }

    func personalInflation(userId _: UUID, country _: MacroCountry, on _: Request) async throws -> PersonalInflationResponse {
        throw Abort(.serviceUnavailable)
    }
}

@Suite("Weekly digest runner", .serialized)
struct DigestRunnerTests {
    /// Sunday 2026-10-25 18:05 UTC.
    private let sundayEvening = Date(timeIntervalSince1970: 1_792_951_500)
    /// Saturday 2026-10-24 18:05 UTC.
    private let saturdayEvening = Date(timeIntervalSince1970: 1_792_865_100)

    private func withApp(_ test: (Application, DigestMailRecorder) async throws -> Void) async throws {
        try await DatabaseTestLock.withSharedAccess {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                let mailer = DigestMailRecorder()
                app.mailer = mailer
                app.digestDataSources = FixedDigestSources()
                var config = DigestConfig()
                config.enabled = true
                config.emailEnabled = true
                config.webBaseURL = "https://norviq.test"
                config.apiBaseURL = "https://api.norviq.test"
                app.digestConfig = config
                try await app.autoMigrate()
                try await test(app, mailer)
                try await app.autoRevert()
                try await app.asyncShutdown()
            } catch {
                try? await app.autoRevert()
                try? await app.asyncShutdown()
                throw error
            }
        }
    }

    private func registerUser(_ app: Application) async throws -> (id: UUID, token: String) {
        let id = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "digest_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "digest_\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            token = try res.content.decode(AuthResponse.self).token
        })
        return try await (app.jwt.keys.verify(token, as: SessionToken.self).userId, token)
    }

    /// A verified user holding 10 AAPL, opted in to the Sunday 18:00 UTC email.
    @discardableResult
    private func optedIn(_ app: Application, verified: Bool = true, holdings: Bool = true) async throws -> (id: UUID, token: String, preference: DigestPreference) {
        let user = try await registerUser(app)
        if verified, let row = try await User.find(user.id, on: app.db) {
            row.emailVerifiedAt = Date()
            try await row.save(on: app.db)
        }
        if holdings {
            let list = PortfolioList(userId: user.id, name: "Main", baseCurrency: "EUR")
            try await list.save(on: app.db)
            try await Stock(
                userId: user.id, portfolioListId: list.requireID(), symbol: "aapl",
                shares: 10, buyPrice: 90, buyDate: Date(timeIntervalSince1970: 1_700_000_000)
            ).save(on: app.db)
        }
        let preference = DigestPreference(userId: user.id, emailEnabled: true, timezone: "UTC")
        try await preference.save(on: app.db)
        return (user.id, user.token, preference)
    }

    private func runner(_ app: Application) -> DigestRunner {
        DigestRunner(config: app.digestConfig, sources: app.digestDataSources)
    }

    @Test("Sends one email with HTML and unsubscribe headers, and never twice")
    func sendsOnce() async throws {
        try await withApp { app, mailer in
            let user = try await optedIn(app)
            let req = Request(application: app, on: app.eventLoopGroup.next())

            let first = try await runner(app).runDue(now: sundayEvening, on: req)
            let second = try await runner(app).runDue(now: sundayEvening.addingTimeInterval(900), on: req)

            #expect(first == .init(claimed: 1, sent: 1, failed: 0))
            #expect(second == .init(claimed: 0, sent: 0, failed: 0))
            let messages = await mailer.messages()
            try #require(messages.count == 1)
            #expect(messages[0].subject == "Your week: +€100.00 (+10.00%)")
            #expect(messages[0].htmlBody?.contains("AAPL") == true)
            #expect(messages[0].body.contains("AAPL reports on 2026-10-28 (after close)"))
            #expect(messages[0].headers["List-Unsubscribe"] == "<https://api.norviq.test/v1/digest/unsubscribe?token=\(user.preference.unsubscribeToken)>")

            let digest = try #require(try await WeeklyDigest.query(on: app.db).filter(\.$userId == user.id).first())
            #expect(digest.status == "sent")
            #expect(digest.periodStart == "2026-10-19")
            #expect(try await WeeklyDigestDelivery.query(on: app.db).count() == 1)
        }
    }

    @Test("Concurrent ticks claim the week once")
    func concurrentClaims() async throws {
        try await withApp { app, mailer in
            try await optedIn(app)
            let runner = runner(app)
            let now = sundayEvening
            async let a = runner.runDue(now: now, on: Request(application: app, on: app.eventLoopGroup.next()))
            async let b = runner.runDue(now: now, on: Request(application: app, on: app.eventLoopGroup.next()))
            let results = try await [a, b]
            #expect(results.map(\.sent).reduce(0, +) == 1)
            #expect(await mailer.messages().count == 1)
        }
    }

    @Test("Nothing before the send day")
    func notDue() async throws {
        try await withApp { app, mailer in
            try await optedIn(app)
            let summary = try await runner(app).runDue(now: saturdayEvening, on: Request(application: app, on: app.eventLoopGroup.next()))
            #expect(summary.claimed == 0)
            #expect(await mailer.messages().isEmpty)
        }
    }

    @Test("Unverified address: no email, the attempt is recorded")
    func unverified() async throws {
        try await withApp { app, mailer in
            try await optedIn(app, verified: false)
            let summary = try await runner(app).runDue(now: sundayEvening, on: Request(application: app, on: app.eventLoopGroup.next()))
            #expect(summary.failed == 1)
            #expect(await mailer.messages().isEmpty)
            let delivery = try #require(try await WeeklyDigestDelivery.query(on: app.db).first())
            #expect(delivery.error == "email_unverified")
        }
    }

    @Test("Users with nothing connected get no digest row")
    func ineligible() async throws {
        try await withApp { app, mailer in
            try await optedIn(app, holdings: false)
            let summary = try await runner(app).runDue(now: sundayEvening, on: Request(application: app, on: app.eventLoopGroup.next()))
            #expect(summary.claimed == 0)
            #expect(try await WeeklyDigest.query(on: app.db).count() == 0)
            #expect(await mailer.messages().isEmpty)
        }
    }

    @Test("The allowlist limits who is sent to")
    func allowlist() async throws {
        try await withApp { app, mailer in
            try await optedIn(app)
            var config = app.digestConfig
            config.allowlist = [UUID()]
            let summary = try await DigestRunner(config: config, sources: app.digestDataSources)
                .runDue(now: sundayEvening, on: Request(application: app, on: app.eventLoopGroup.next()))
            #expect(summary.claimed == 0)
            #expect(await mailer.messages().isEmpty)
        }
    }

    @Test("With the email channel off nothing is claimed")
    func emailChannelOff() async throws {
        try await withApp { app, mailer in
            try await optedIn(app)
            var config = app.digestConfig
            config.emailEnabled = false
            let summary = try await DigestRunner(config: config, sources: app.digestDataSources)
                .runDue(now: sundayEvening, on: Request(application: app, on: app.eventLoopGroup.next()))
            #expect(summary.claimed == 0)
            #expect(await mailer.messages().isEmpty)
        }
    }

    // MARK: - Routes

    @Test("One-click unsubscribe is idempotent and does not reveal tokens")
    func unsubscribe() async throws {
        try await withApp { app, _ in
            let user = try await optedIn(app)
            for token in [user.preference.unsubscribeToken, user.preference.unsubscribeToken, "unknown-token"] {
                try await app.testing().test(.POST, "v1/digest/unsubscribe?token=\(token)", afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(try res.content.decode(DigestUnsubscribeResponse.self).unsubscribed)
                })
            }
            let row = try #require(try await DigestPreference.query(on: app.db).filter(\.$userId == user.id).first())
            #expect(row.emailEnabled == false)
        }
    }

    @Test("Unsubscribe still works with the feature off")
    func unsubscribeWhileDisabled() async throws {
        try await withApp { app, _ in
            let user = try await optedIn(app)
            app.digestConfig.enabled = false
            try await app.testing().test(.POST, "v1/digest/unsubscribe?token=\(user.preference.unsubscribeToken)", afterResponse: { res async in
                #expect(res.status == .ok)
            })
            try await app.testing().test(.GET, "v1/digest-preferences", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("Preferences: undecided until saved, validated, merged")
    func preferences() async throws {
        try await withApp { app, _ in
            let user = try await registerUser(app)
            let auth: (inout TestingHTTPRequest) throws -> Void = { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }
            try await app.testing().test(.GET, "v1/digest-preferences", beforeRequest: auth, afterResponse: { res async throws in
                let body = try res.content.decode(DigestPreferencesResponse.self)
                #expect(body.decided == false)
                #expect(body.weekday == 7 && body.localHour == 18)
            })
            try await app.testing().test(.PUT, "v1/digest-preferences", beforeRequest: { req in
                try auth(&req)
                try req.content.encode(DigestPreferencesUpdate(timezone: "Mars/Olympus"))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
            try await app.testing().test(.PUT, "v1/digest-preferences", beforeRequest: { req in
                try auth(&req)
                try req.content.encode(DigestPreferencesUpdate(emailEnabled: true, timezone: "Europe/Lisbon", country: "pt"))
            }, afterResponse: { res async throws in
                let body = try res.content.decode(DigestPreferencesResponse.self)
                #expect(body.decided && body.emailEnabled && !body.pushEnabled)
                #expect(body.timezone == "Europe/Lisbon" && body.country == "PT")
            })
            try await app.testing().test(.PUT, "v1/digest-preferences", beforeRequest: { req in
                try auth(&req)
                try req.content.encode(DigestPreferencesUpdate(pushEnabled: true))
            }, afterResponse: { res async throws in
                let body = try res.content.decode(DigestPreferencesResponse.self)
                #expect(body.emailEnabled && body.pushEnabled && body.timezone == "Europe/Lisbon")
            })
        }
    }

    @Test("A digest is visible to its owner only")
    func ownership() async throws {
        try await withApp { app, _ in
            let owner = try await optedIn(app)
            let other = try await registerUser(app)
            _ = try await runner(app).runDue(now: sundayEvening, on: Request(application: app, on: app.eventLoopGroup.next()))
            let digest = try #require(try await WeeklyDigest.query(on: app.db).filter(\.$userId == owner.id).first())
            let path = "v1/digests/\(try digest.requireID())"

            try await app.testing().test(.GET, path, beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: owner.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(DigestResponse.self)
                #expect(body.payload.movers.first?.symbol == "AAPL")
                #expect(body.headline == "Your week: +€100.00 (+10.00%). AAPL did most of it.")
            })
            try await app.testing().test(.GET, path, beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: other.token)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
            try await app.testing().test(.GET, "v1/digests", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: owner.token)
            }, afterResponse: { res async throws in
                #expect(try res.content.decode(DigestListResponse.self).items.count == 1)
            })
        }
    }
}
