import Fluent
import Foundation
import Redis
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

// MARK: - Fixtures

private enum RecentEarningsFixture {
    /// One row. `actual == nil` is how the provider represents a quarter that
    /// has been scheduled but not yet reported.
    static func row(
        _ date: String,
        estimate: Double?,
        actual: Double?,
        symbol: String = "AAPL",
        hasTranscript: Bool = false
    ) -> EarningsResponse {
        EarningsResponse(
            symbol: symbol,
            date: date,
            epsActual: actual,
            epsEstimated: estimate,
            revenueActual: nil,
            revenueEstimated: nil,
            lastUpdated: nil,
            surprisePercent: actual.flatMap { actual in
                estimate.flatMap { estimate in
                    estimate == 0 ? nil : ((actual - estimate) / abs(estimate)) * 100
                }
            },
            hasTranscript: hasTranscript
        )
    }

    /// Six consecutive beats, newest last, plus one scheduled quarter.
    ///
    /// Six matters: a run longer than the four rows the teaser returns is the
    /// only fixture that can tell "annotate the whole history, then slice" apart
    /// from "slice, then annotate".
    static let sixBeatsAndAScheduledQuarter: [EarningsResponse] = [
        row("2024-03-01", estimate: 0.9, actual: 1.0),
        row("2024-06-01", estimate: 1.0, actual: 1.1),
        row("2024-09-01", estimate: 1.1, actual: 1.2),
        row("2024-12-01", estimate: 1.2, actual: 1.3),
        row("2025-03-01", estimate: 1.3, actual: 1.4),
        row("2025-06-01", estimate: 1.4, actual: 1.5, hasTranscript: true),
        row("2025-09-01", estimate: 1.6, actual: nil),
    ]
}

// MARK: - Selection

/// Which rows the teaser picks out of a symbol's earnings history, and how it
/// labels them. Pure: no app, no provider, no cache.
@Suite("Recent earnings selection")
struct RecentEarningsSelectionTests {
    /// `today` is pinned rather than read from the clock: it only matters for a
    /// symbol with no reported quarter at all, and a test that drifted with the
    /// calendar would be worse than no test.
    private func build(
        _ history: [EarningsResponse],
        symbol: String = "AAPL",
        today: String = "2026-09-18"
    ) -> RecentEarningsResponse {
        RecentEarnings.build(symbol: symbol, history: EarningsStreak.annotate(history), today: today)
    }

    @Test("Four reported quarters are returned when more exist, newest first")
    func fourReportedQuartersWhenMoreExist() {
        let response = build(RecentEarningsFixture.sixBeatsAndAScheduledQuarter)

        #expect(response.quarters.count == 4)
        #expect(response.quarters.map(\.date) == ["2025-06-01", "2025-03-01", "2024-12-01", "2024-09-01"])
        #expect(response.quarters.allSatisfy { $0.status == .reported })
    }

    @Test("Fewer reported quarters are returned when fewer exist")
    func fewerWhenFewerExist() {
        let response = build([
            RecentEarningsFixture.row("2025-03-01", estimate: 1.3, actual: 1.4),
            RecentEarningsFixture.row("2025-06-01", estimate: 1.4, actual: 1.5),
        ])

        #expect(response.quarters.count == 2)
        #expect(response.quarters.map(\.date) == ["2025-06-01", "2025-03-01"])
    }

    @Test("The scheduled quarter is marked and does not consume a reported slot")
    func theScheduledQuarterDoesNotConsumeAReportedSlot() throws {
        let response = build(RecentEarningsFixture.sixBeatsAndAScheduledQuarter)

        let scheduled = try #require(response.nextScheduled)
        #expect(scheduled.date == "2025-09-01")
        #expect(scheduled.status == .scheduled)
        #expect(scheduled.epsActual == nil)
        // Both streaks zero: the row carries no comparable result. Emphatically
        // not a miss.
        #expect(scheduled.beatStreak == 0)
        #expect(scheduled.missStreak == 0)
        // Four reported rows are still returned, and the scheduled one is not
        // among them.
        #expect(response.quarters.count == 4)
        #expect(!response.quarters.map(\.date).contains("2025-09-01"))
    }

    @Test("No scheduled quarter is reported when the provider lists none")
    func noScheduledQuarterWhenTheProviderListsNone() {
        let reportedOnly = RecentEarningsFixture.sixBeatsAndAScheduledQuarter.dropLast()
        let response = build(Array(reportedOnly))

        #expect(response.nextScheduled == nil)
        #expect(response.quarters.count == 4)
    }

    @Test("An unreported row older than the last report is not the next scheduled quarter")
    func anOldUnreportedRowIsNotScheduled() {
        // A quarter the provider never filled in an estimate for. It is
        // unreported, but it is history, not a date to put on the page.
        let response = build([
            RecentEarningsFixture.row("2023-06-01", estimate: nil, actual: 0.5),
            RecentEarningsFixture.row("2025-03-01", estimate: 1.3, actual: 1.4),
            RecentEarningsFixture.row("2025-06-01", estimate: 1.4, actual: 1.5),
        ])

        #expect(response.nextScheduled == nil)
        #expect(response.quarters.map(\.date) == ["2025-06-01", "2025-03-01"])
    }

    @Test("An empty history is an empty answer, not an error")
    func anEmptyHistoryIsAnEmptyAnswer() {
        let response = build([])

        #expect(response.symbol == "AAPL")
        #expect(response.quarters.isEmpty)
        #expect(response.nextScheduled == nil)
    }

    @Test("The earliest of several upcoming quarters is the next scheduled one")
    func theEarliestUpcomingQuarterIsChosen() {
        // Two un-reported rows after the last report. `.last(where:)` over a
        // newest-first array means "earliest match", which is correct but is not
        // obvious from reading it — this is the test that says so.
        let response = build([
            RecentEarningsFixture.row("2025-06-01", estimate: 1.4, actual: 1.5),
            RecentEarningsFixture.row("2025-09-01", estimate: 1.6, actual: nil),
            RecentEarningsFixture.row("2025-12-01", estimate: 1.7, actual: nil),
        ])

        #expect(response.nextScheduled?.date == "2025-09-01")
    }

    @Test("A scheduled row can carry an EPS actual, because scheduled means not comparable")
    func aScheduledRowCanCarryAnActual() throws {
        // `scheduled` is `!isReported`, which is "actual OR estimate missing" —
        // not "no actual". A row the provider lists with an actual but no
        // estimate is scheduled and keeps its actual. The schema says so; this
        // pins it, because the opposite claim would flow into the generated
        // client's doc comments.
        let response = build([
            RecentEarningsFixture.row("2025-03-01", estimate: 1.3, actual: 1.4),
            RecentEarningsFixture.row("2025-06-01", estimate: 1.4, actual: 1.5),
            RecentEarningsFixture.row("2025-09-01", estimate: nil, actual: 0.5),
        ])

        let scheduled = try #require(response.nextScheduled)
        #expect(scheduled.date == "2025-09-01")
        #expect(scheduled.status == .scheduled)
        #expect(scheduled.epsActual == 0.5)
        #expect(scheduled.epsEstimated == nil)
        // Still no comparable result, so still no run.
        #expect(scheduled.beatStreak == 0)
        #expect(scheduled.missStreak == 0)
    }

    // MARK: - No reported quarter at all

    @Test("With nothing reported, a quarter in the past is not offered as the next one")
    func withNothingReportedAPastQuarterIsNotNext() {
        // A newly listed company: the provider lists dates but has reported no
        // comparable result. Without a last report to anchor to, "next" can only
        // mean "not in the past" — otherwise the oldest row in the history wins
        // and the page prints a next-report date from years ago.
        let response = build(
            [
                RecentEarningsFixture.row("2020-01-01", estimate: nil, actual: nil),
                RecentEarningsFixture.row("2026-12-01", estimate: 1.0, actual: nil),
            ],
            today: "2026-09-18"
        )

        #expect(response.quarters.isEmpty)
        #expect(response.nextScheduled?.date == "2026-12-01")
    }

    @Test("With nothing reported and nothing upcoming, there is no next scheduled quarter")
    func withNothingReportedAndNothingUpcomingThereIsNoNext() {
        let response = build(
            [
                RecentEarningsFixture.row("2020-01-01", estimate: nil, actual: nil),
                RecentEarningsFixture.row("2021-01-01", estimate: nil, actual: nil),
            ],
            today: "2026-09-18"
        )

        #expect(response.quarters.isEmpty)
        #expect(response.nextScheduled == nil)
    }

    @Test("A quarter dated today still counts as upcoming")
    func aQuarterDatedTodayCountsAsUpcoming() {
        let response = build(
            [RecentEarningsFixture.row("2026-09-18", estimate: 1.0, actual: nil)],
            today: "2026-09-18"
        )

        #expect(response.nextScheduled?.date == "2026-09-18")
    }

    @Test("The response carries transcript availability but never transcript text")
    func theResponseCarriesNoTranscriptText() throws {
        let response = build(RecentEarningsFixture.sixBeatsAndAScheduledQuarter)
        let json = try #require(String(data: JSONEncoder().encode(response), encoding: .utf8))

        // The availability flag is deliberately kept: it is metadata about a
        // public earnings call, and the page needs it to decide whether to
        // offer the Pro transcript link at all.
        #expect(response.quarters.first?.hasTranscript == true)
        // The content is not.
        #expect(!json.contains("\"content\""))
        #expect(!json.contains("\"transcript\""))
    }
}

// MARK: - Service

/// The wiring the selection suite cannot see: which upstream calls happen, and
/// what is written to the cache.
@Suite("Recent earnings service", .serialized)
struct RecentEarningsServiceTests {
    /// Boots a configured app, hands the test a stub-backed service and a
    /// detached request, and tears down.
    ///
    /// No migrations: the teaser never touches `req.db`, and skipping them keeps
    /// this suite off the database lock. Redis is disabled in `.testing` by
    /// `configureDatabase`, so — like the ownership suite — this one opts back
    /// in, because "the teaser has its own cache entry" is a statement about
    /// Redis and there is no injectable fake behind `redisSetValue`.
    private func withService(
        _ test: (RecentEarningsStub, DefaultMarketDataService, Request, Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            if let url = Environment.get("REDIS_URL"), !url.isEmpty,
               let configuration = try? RedisConfiguration(url: url)
            {
                app.redis.configuration = configuration
            }
            try await app.asyncBoot()
            let stub = RecentEarningsStub()
            let service = DefaultMarketDataService(
                provider: DisabledMarketDataProvider(),
                fmpProvider: RecentEarningsStubProvider(state: stub),
                cacheConfig: .init(
                    quoteTTLSeconds: 3600,
                    historyTTLSeconds: 3600,
                    searchTTLSeconds: 3600,
                    fxTTLSeconds: 3600,
                    profileTTLSeconds: 3600,
                    basicFinancialsTTLSeconds: 3600,
                    fmpTTLSeconds: 3600,
                    ownershipTTLSeconds: 3600,
                    recentEarningsTTLSeconds: 3600,
                    defaultCurrency: "USD"
                ),
                // Pinned rather than read from the environment, so the
                // per-test unique symbol is not refused by the free tier's
                // symbol allow-list before the stub is ever asked.
                fmpAccessTier: .premium
            )
            let req = Request(
                application: app,
                method: .GET,
                url: URI(string: "/internal/recent-earnings-test"),
                on: app.eventLoopGroup.next()
            )
            try await test(stub, service, req, app)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    /// A symbol no other test in the run uses, so a Redis entry left by an
    /// earlier run or an earlier test cannot answer this one.
    private func uniqueSymbol() -> String {
        "T" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).uppercased()
    }

    @Test("Streak values match what the full earnings route reports for the same history")
    func streaksMatchTheFullEarningsRoute() async throws {
        try await withService { stub, service, req, _ in
            let symbol = uniqueSymbol()
            await stub.setRows(RecentEarningsFixture.sixBeatsAndAScheduledQuarter)

            let teaser = try await service.recentEarnings(symbol: symbol, on: req)
            // Exactly the expression `MarketDataController.earnings` evaluates
            // for the Pro-gated route.
            let full = try await EarningsStreak.annotate(
                service.earnings(symbol: symbol, limit: nil, on: req)
            )
            let fullByDate = Dictionary(uniqueKeysWithValues: full.map { ($0.date, $0) })

            #expect(!teaser.quarters.isEmpty)
            for quarter in teaser.quarters {
                let reference = try #require(fullByDate[quarter.date])
                #expect(quarter.beatStreak == reference.beatStreak)
                #expect(quarter.missStreak == reference.missStreak)
            }
            // The oldest returned quarter closes a run of 3, which only holds if
            // the streaks were counted over the whole history before slicing.
            #expect(teaser.quarters.map(\.beatStreak) == [6, 5, 4, 3])

            let scheduled = try #require(teaser.nextScheduled)
            let scheduledReference = try #require(fullByDate[scheduled.date])
            #expect(scheduled.beatStreak == scheduledReference.beatStreak)
            #expect(scheduled.missStreak == scheduledReference.missStreak)
        }
    }

    @Test("The teaser is served from its own cache entry on the second call")
    func theSecondCallIsServedFromTheTeaserCache() async throws {
        try await withService { stub, service, req, app in
            // Needs REDIS_URL, which CI's redis:7-alpine service provides and
            // `.env` sets locally. Failing loudly rather than skipping: a silent
            // skip would make this test pass while proving nothing.
            try #require(app.redis.configuration != nil)

            let symbol = uniqueSymbol()
            await stub.setRows(RecentEarningsFixture.sixBeatsAndAScheduledQuarter)

            let first = try await service.recentEarnings(symbol: symbol, on: req)
            #expect(await stub.earningsCalls == 1)

            // Drop the *inner* earnings cache, so the only thing that can answer
            // the second call without going upstream is the teaser's own entry.
            _ = try? await app.redis.delete(RedisKey("market:earnings:fmp:\(symbol):100")).get()

            let second = try await service.recentEarnings(symbol: symbol, on: req)
            #expect(await stub.earningsCalls == 1)
            #expect(second == first)

            // And the entry is where the route says it is.
            let cached = try await app.redis
                .get(RedisKey(RecentEarnings.redisKey(symbol: symbol)), as: Data.self).get()
            #expect(cached != nil)
        }
    }
}

// MARK: - Route

/// What the teaser route refuses, what it does not, and how it is registered.
@Suite("Recent earnings route", .serialized)
struct RecentEarningsRouteTests {
    private func withApp(
        billingBypass: Bool? = nil,
        _ test: @escaping (Application) async throws -> Void
    ) async throws {
        try await DatabaseTestLock.withLock {
            let previousBypass = getenv("BYPASS_BILLING").map { String(cString: $0) }
            if let billingBypass {
                setenv("BYPASS_BILLING", billingBypass ? "true" : "false", 1)
            }
            defer {
                if billingBypass != nil {
                    if let previousBypass {
                        setenv("BYPASS_BILLING", previousBypass, 1)
                    } else {
                        unsetenv("BYPASS_BILLING")
                    }
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

    private func registerUser(app: Application) async throws -> (token: String, userId: UUID) {
        let identifier = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "teaser_\(identifier)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "teaser_\(identifier)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            token = try res.content.decode(AuthResponse.self).token
        })
        let session = try await app.jwt.keys.verify(token, as: SessionToken.self)
        return (token, session.userId)
    }

    /// Mints a PAT directly, the way `MCPTokenAuthTests` does, so this test does
    /// not need a Pro entitlement to get a token in the first place.
    private func mintPAT(app: Application, userId: UUID, scopes: [APIScope]) async throws -> String {
        let raw = OpaqueToken.generate(prefix: OpaqueToken.patPrefix)
        let pat = PersonalAccessToken(
            userId: userId,
            name: "test",
            tokenHash: OpaqueToken.sha256Hex(raw),
            scopes: scopes.map(\.rawValue),
            expiresAt: Date().addingTimeInterval(3600)
        )
        try await pat.save(on: app.db)
        return raw
    }

    @Test("The teaser route is registered under the market group, beside the Pro route")
    func theRouteIsRegistered() async throws {
        try await withApp { app in
            let paths = app.routes.all
                .filter { $0.method == .GET }
                .map { $0.path.map(\.description).joined(separator: "/") }

            #expect(paths.contains("v1/market/earnings/:symbol/recent"))
            #expect(paths.contains("v1/market/earnings/:symbol"))
            // The literal third segment must not be shadowed by a parameter
            // route at the same depth. There is none today; this pins it.
            #expect(!paths.contains { $0.hasPrefix("v1/market/earnings/:symbol/:") })
        }
    }

    @Test("The teaser route needs a session, like every other market route")
    func theRouteRequiresASession() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/market/earnings/AAPL/recent", afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("A non-Pro market:read token reaches the teaser but is still refused the Pro earnings route")
    func aNonProTokenReachesTheTeaserButNotTheProRoute() async throws {
        try await withApp(billingBypass: false) { app in
            let user = try await registerUser(app: app)
            // Registration starts a trial, and a trial resolves as Pro. The
            // public page's service account is long past that.
            let account = try #require(try await User.find(user.userId, on: app.db))
            account.trialStartedAt = nil
            account.trialDays = nil
            account.trialTier = nil
            try await account.save(on: app.db)

            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.marketRead])

            // The premium gate on the existing route is untouched.
            try await app.testing().test(.GET, "v1/market/earnings/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("upgrade_required"))
            })

            // The transcript route stays Pro too.
            try await app.testing().test(.GET, "v1/market/earnings/AAPL/transcript", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("upgrade_required"))
            })

            // The teaser gets past the entitlement check. No FMP provider is
            // configured in the test app, so it answers 503 — which it can only
            // do after auth, the scope check and routing have all passed. The
            // claim is "not gated", so the assertion is exactly that.
            try await app.testing().test(.GET, "v1/market/earnings/AAPL/recent", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                // The positive, not three negatives: the test app configures no
                // FMP provider, so a teaser that got all the way past auth, the
                // scope check, routing and the (absent) entitlement gate lands
                // on exactly 503. Asserting that makes the test fail loudly if
                // the route ever 404s or 400s short of the gate instead of
                // quietly still "not being forbidden".
                #expect(res.status == .serviceUnavailable)
                #expect(!res.body.string.contains("upgrade_required"))
            })
        }
    }

    @Test("A token without market:read is still refused the teaser")
    func aTokenWithoutMarketReadIsRefused() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesRead])
            try await app.testing().test(.GET, "v1/market/earnings/AAPL/recent", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
        }
    }
}
