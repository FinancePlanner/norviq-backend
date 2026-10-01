import Fluent
import FluentSQL
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("XP level curve and period returns")
struct XPMathTests {
    @Test("Level L starts at 50·L·(L−1) XP")
    func levelCurve() {
        #expect(XPLevel.level(for: 0) == 1)
        #expect(XPLevel.level(for: 99) == 1)
        #expect(XPLevel.level(for: 100) == 2)
        #expect(XPLevel.level(for: 299) == 2)
        #expect(XPLevel.level(for: 300) == 3)
        #expect(XPLevel.level(for: 1000) == 5)
        #expect(XPLevel.progress(for: 50) == 0.5)
        #expect(XPLevel.progress(for: 110) == 0.05)
        #expect(XPLevel.level(for: -5) == 1)
    }

    @Test("Streaks survive until a whole day passes, and count the longest run")
    func streakMath() {
        #expect(XPService.currentStreak(days: [10, 11, 12], today: 12) == 3)
        #expect(XPService.currentStreak(days: [10, 11, 12], today: 13) == 3)
        #expect(XPService.currentStreak(days: [10, 11, 12], today: 14) == 0)
        #expect(XPService.currentStreak(days: [], today: 14) == 0)
        #expect(XPService.longestStreak(days: [1, 2, 3, 7, 8]) == 3)
    }

    @Test("Buying more is a flow, not a gain")
    func timeWeightedReturn() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let day = { (offset: Int) in
            PortfolioSnapshotValuator.addDays(PortfolioSnapshotValuator.startOfDay(start), days: offset)
        }
        let points = [
            LeaderboardReturns.Point(day: day(0), marketValue: 100, costBasis: 100),
            LeaderboardReturns.Point(day: day(1), marketValue: 110, costBasis: 100),
            // Bought 100 more at cost; the holding itself was flat.
            LeaderboardReturns.Point(day: day(2), marketValue: 210, costBasis: 200),
        ]
        let percent = try #require(LeaderboardReturns.timeWeightedPercent(points, periodStart: day(0)))
        #expect(abs(percent - 10) < 0.001)
        #expect(LeaderboardReturns.timeWeightedPercent(Array(points.prefix(1)), periodStart: day(0)) == nil)
    }
}

/// XP, check-ins and leaderboards against a real database.
@Suite("Gamification routes", .serialized)
struct GamificationRouteTests {
    private func withApp(leaderboards: Bool = true, _ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            setenv("SOCIAL_ENABLED", "1", 1)
            setenv("SOCIAL_LEADERBOARDS_ENABLED", leaderboards ? "1" : "0", 1)
            defer { unsetenv("SOCIAL_LEADERBOARDS_ENABLED") }
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

    private func register(_ app: Application, _ id: String) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "gam_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "gam+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
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

    private func headers(_ auth: AuthResponse) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = BearerAuthorization(token: auth.token)
        headers.add(name: GamificationCalendar.timezoneHeader, value: "UTC")
        return headers
    }

    private func send<T: Decodable>(
        _ app: Application, _ method: HTTPMethod, _ path: String, as auth: AuthResponse, _: T.Type,
        body: (any Content)? = nil
    ) async throws -> T {
        var value: T?
        try await app.testing().test(method, path, headers: headers(auth), beforeRequest: { req in
            if let body {
                try req.content.encode(body)
            }
        }, afterResponse: { res async throws in
            #expect(res.status == .ok, "\(method) \(path) -> \(res.status)")
            value = try res.content.decode(T.self)
        })
        return try #require(value)
    }

    private func status(_ app: Application, _ method: HTTPMethod, _ path: String, as auth: AuthResponse) async throws -> HTTPStatus {
        var status: HTTPStatus = .internalServerError
        try await app.testing().test(method, path, headers: headers(auth)) { res async throws in
            status = res.status
        }
        return status
    }

    private func leaderboard(
        _ app: Application, _ metric: String, as auth: AuthResponse
    ) async throws -> LeaderboardResponseDTO {
        try await send(app, .GET, "v1/social/leaderboards?metric=\(metric)&period=week", as: auth, LeaderboardResponseDTO.self)
    }

    private func utcDay(_ offset: Int) -> String {
        GamificationCalendar.localDate(Date().addingTimeInterval(Double(offset) * 86400), in: GamificationCalendar.utc)
    }

    private func setPrivacy(_ app: Application, _ auth: AuthResponse, _ change: (inout SocialPrivacySettingsDTO) -> Void) async throws {
        var settings = SocialPrivacySettingsDTO.default
        change(&settings)
        _ = try await send(app, .PUT, "v1/social/privacy", as: auth, SocialPrivacySettingsDTO.self, body: settings)
    }

    @Test("Config advertises leaderboards; switching them off 404s the routes")
    func flag() async throws {
        try await withApp { app in
            let a = try await register(app, "cfg1")
            let config = try await send(app, .GET, "v1/social/config", as: a, SocialConfigDTO.self)
            #expect(config.leaderboards)
        }
        try await withApp(leaderboards: false) { app in
            let a = try await register(app, "cfg2")
            let config = try await send(app, .GET, "v1/social/config", as: a, SocialConfigDTO.self)
            #expect(config.leaderboards == false)
            #expect(try await status(app, .POST, "v1/gamification/check-in", as: a) == .notFound)
            #expect(try await status(app, .GET, "v1/social/leaderboards", as: a) == .notFound)
        }
    }

    @Test("Check-in is idempotent per local day and pays XP once")
    func checkInIdempotent() async throws {
        try await withApp { app in
            let a = try await register(app, "chk1")
            let first = try await send(app, .POST, "v1/gamification/check-in", as: a, CheckInResponseDTO.self)
            #expect(first == CheckInResponseDTO(streak: 1, xpAwarded: XPRules.checkIn, alreadyCheckedIn: false))
            let second = try await send(app, .POST, "v1/gamification/check-in", as: a, CheckInResponseDTO.self)
            #expect(second == CheckInResponseDTO(streak: 1, xpAwarded: 0, alreadyCheckedIn: true))

            let xp = try await send(app, .GET, "v1/gamification/xp", as: a, XPSummaryDTO.self)
            #expect(xp == XPSummaryDTO(total: 10, level: 1, levelProgress: 0.1, weekXP: 10))
            let history = try await send(app, .GET, "v1/gamification/xp/events", as: a, XPHistoryResponseDTO.self)
            #expect(history.events.map(\.type) == [XPEventTypeDTO.checkIn.rawValue])
            #expect(history.nextCursor == nil)
        }
    }

    @Test("Streaks run across days, pay the 7-day bonus and reset after a gap")
    func streakAcrossDays() async throws {
        try await withApp { app in
            let a = try await register(app, "stk1")
            for offset in 1 ... 6 {
                try await GamificationCheckIn(userId: a.userId, localDate: utcDay(-offset), timeZone: "UTC").save(on: app.db)
            }
            let response = try await send(app, .POST, "v1/gamification/check-in", as: a, CheckInResponseDTO.self)
            #expect(response.streak == 7)
            #expect(response.xpAwarded == XPRules.checkIn + 50)

            let streaks = try await send(app, .GET, "v1/gamification/streaks", as: a, StreakSummaryDTO.self)
            #expect(streaks.checkInCurrent == 7)
            #expect(streaks.checkInLongest == 7)
            #expect(streaks.lastCheckInDate == utcDay(0))

            let b = try await register(app, "stk2")
            for offset in [3, 4, 5] {
                try await GamificationCheckIn(userId: b.userId, localDate: utcDay(-offset), timeZone: "UTC").save(on: app.db)
            }
            let broken = try await send(app, .POST, "v1/gamification/check-in", as: b, CheckInResponseDTO.self)
            #expect(broken.streak == 1)
            let bStreaks = try await send(app, .GET, "v1/gamification/streaks", as: b, StreakSummaryDTO.self)
            #expect(bStreaks.checkInLongest == 3)
        }
    }

    @Test("Weekly XP ignores older events; the level uses the total")
    func xpSummaryMath() async throws {
        try await withApp { app in
            let a = try await register(app, "xps1")
            _ = try await send(app, .POST, "v1/gamification/check-in", as: a, CheckInResponseDTO.self)
            let old = GamificationXPEvent(userId: a.userId, type: .badgeEarned, points: 100, dedupeKey: "test:old")
            try await old.save(on: app.db)
            let oldId = try #require(old.id)
            let sql = try #require(app.db as? any SQLDatabase)
            let monthAgo = Date().addingTimeInterval(-30 * 86400)
            try await sql.raw("UPDATE gamification_xp_events SET created_at = \(bind: monthAgo) WHERE id = \(bind: oldId)").run()

            let xp = try await send(app, .GET, "v1/gamification/xp", as: a, XPSummaryDTO.self)
            #expect(xp.total == 110)
            #expect(xp.weekXP == 10)
            #expect(xp.level == 2)
            #expect(abs(xp.levelProgress - 0.05) < 0.0001)
        }
    }

    @Test("Budget streak reports are capped by what expense data supports")
    func budgetStreakVerified() async throws {
        try await withApp { app in
            let a = try await register(app, "bud1")
            // No expense data: the server can't confirm any month.
            let streaks = try await send(
                app, .POST, "v1/gamification/streaks/budget", as: a, StreakSummaryDTO.self,
                body: BudgetStreakReportBody(months: 50)
            )
            #expect(streaks.budgetMonths == 0)
            let xp = try await send(app, .GET, "v1/gamification/xp", as: a, XPSummaryDTO.self)
            #expect(xp.total == 0)

            // A verified level pays once; repeating it pays nothing.
            #expect(try await XPService.recordBudgetStreak(userId: a.userId, reported: 3, verified: 5, on: app.db) == 3)
            try await XPService.recordBudgetStreak(userId: a.userId, reported: 3, verified: 5, on: app.db)
            let after = try await send(app, .GET, "v1/gamification/xp", as: a, XPSummaryDTO.self)
            #expect(after.total == XPRules.budgetStreakMonth * 3)
        }
    }

    @Test("Leaderboards rank only me and my friends")
    func friendsOnly() async throws {
        try await withApp { app in
            let a = try await register(app, "lb1")
            let b = try await register(app, "lb2")
            let c = try await register(app, "lb3")
            try await SocialService.befriend(a.userId, b.userId, on: app.db)
            _ = try await send(app, .POST, "v1/gamification/check-in", as: a, CheckInResponseDTO.self)
            _ = try await send(app, .POST, "v1/gamification/check-in", as: c, CheckInResponseDTO.self)
            try await XPService.award(.badgeEarned, points: 40, to: b.userId, dedupeKey: "test:b", on: app.db)

            let board = try await leaderboard(app, "xp", as: a)
            #expect(board.entries.map(\.user.id) == [b.userId, a.userId])
            #expect(board.entries.map(\.value) == [40, 10])
            #expect(board.entries.map(\.rank) == [1, 2])
            #expect(board.entries.map(\.isMe) == [false, true])
            #expect(board.periodStart < board.periodEnd)

            let streaks = try await leaderboard(app, "check_in_streak", as: a)
            #expect(Set(streaks.entries.map(\.user.id)) == [a.userId, b.userId])
            #expect(streaks.entries.first?.user.id == a.userId)

            #expect(try await status(app, .GET, "v1/social/leaderboards?metric=money", as: a) == .badRequest)
        }
    }

    @Test("Opting out or blocking removes someone from the board")
    func optOutAndBlock() async throws {
        try await withApp { app in
            let a = try await register(app, "opt1")
            let b = try await register(app, "opt2")
            let c = try await register(app, "opt3")
            try await SocialService.befriend(a.userId, b.userId, on: app.db)
            try await SocialService.befriend(a.userId, c.userId, on: app.db)

            try await setPrivacy(app, b) { $0.leaderboardOptIn = false }
            var ids = try await leaderboard(app, "xp", as: a).entries.map(\.user.id)
            #expect(Set(ids) == [a.userId, c.userId])

            #expect(try await status(app, .POST, "v1/social/blocks/\(a.userId)", as: c) == .noContent)
            ids = try await leaderboard(app, "xp", as: a).entries.map(\.user.id)
            #expect(ids == [a.userId])
            // The blocker doesn't see the blocked person either.
            ids = try await leaderboard(app, "xp", as: c).entries.map(\.user.id)
            #expect(ids == [c.userId])
        }
    }

    @Test("Return % needs showReturnPercent and real snapshot history")
    func returnPercentOptIn() async throws {
        try await withApp { app in
            let a = try await register(app, "ret1")
            let b = try await register(app, "ret2")
            try await SocialService.befriend(a.userId, b.userId, on: app.db)
            // A baseline the day before the week starts, and today's value.
            let week = GamificationCalendar.period(.week, containing: Date(), in: GamificationCalendar.utc)
            let baseline = PortfolioSnapshotValuator.addDays(PortfolioSnapshotValuator.startOfDay(week.start), days: -1)
            // On a Monday "today" is the week start itself, which would leave
            // nothing after the baseline to measure; use the next day then.
            let today = max(
                PortfolioSnapshotValuator.startOfDay(Date()),
                PortfolioSnapshotValuator.addDays(PortfolioSnapshotValuator.startOfDay(week.start), days: 1)
            )
            for (user, gain) in [(a.userId, 10.0), (b.userId, 5.0)] {
                let listId = try await ensureDefaultPortfolioListId(userId: user, on: app.db)
                for (day, value) in [(baseline, 100.0), (today, 100.0 + gain)] {
                    try await PortfolioValueSnapshot(
                        userId: user,
                        portfolioListId: listId,
                        capturedOn: day,
                        currency: "USD",
                        marketValue: value,
                        costBasis: 100,
                        cashBalance: 0,
                        positionCount: 1,
                        source: .live,
                        pricedSymbols: 1,
                        missingSymbols: 0
                    ).save(on: app.db)
                }
            }

            // Return % is off by default: nobody is ranked.
            var board = try await leaderboard(app, "return_percent", as: a)
            #expect(board.entries.isEmpty)

            try await setPrivacy(app, b) { $0.showReturnPercent = true }
            board = try await leaderboard(app, "return_percent", as: a)
            #expect(board.entries.map(\.user.id) == [b.userId])
            #expect(board.entries.first.map { abs($0.value - 5) < 0.001 } == true)

            try await setPrivacy(app, a) { $0.showReturnPercent = true }
            board = try await leaderboard(app, "return_percent", as: a)
            #expect(board.entries.map(\.user.id) == [a.userId, b.userId])
        }
    }
}
