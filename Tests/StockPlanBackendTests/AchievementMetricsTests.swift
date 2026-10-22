import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// `AchievementMetrics.measure` against a real database.
@Suite("Achievement metrics", .serialized)
struct AchievementMetricsTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
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
            username: "achm_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "achm+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
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

    private func context(_ app: Application) -> AchievementContext {
        AchievementContext(db: app.db, logger: app.logger, app: app, now: Date())
    }

    @Test("Counts respect thesis, deletion, AI posts, revocation and archiving")
    func countsRespectFilters() async throws {
        try await withApp { app in
            let user = try await register(app, "counts")
            let userId = user.userId

            try await ResearchNote(userId: userId, symbol: "AAPL", thesis: "Services keep compounding.").save(on: app.db)
            try await ResearchNote(userId: userId, symbol: "MSFT", thesis: "   ").save(on: app.db)

            let board = Board(slug: "achm-board", name: "Achm", description: "Test board", creatorId: userId)
            try await board.save(on: app.db)
            let boardId = try board.requireID()

            let visible = BoardPost(boardId: boardId, authorId: userId, kind: "text", title: "Hello", url: nil, domain: nil, body: "Hi", tags: [])
            visible.score = 12
            try await visible.save(on: app.db)

            let deleted = BoardPost(boardId: boardId, authorId: userId, kind: "text", title: "Gone", url: nil, domain: nil, body: "x", tags: [])
            deleted.score = 50
            try await deleted.save(on: app.db)
            try await deleted.delete(on: app.db)

            let generated = BoardPost(boardId: boardId, authorId: userId, kind: "text", title: "Bot", url: nil, domain: nil, body: "y", tags: [])
            generated.score = 40
            generated.aiGenerated = true
            try await generated.save(on: app.db)

            try await PersonalAccessToken(
                userId: userId, name: "cli", tokenHash: "hash-achm-1", scopes: ["read"],
                expiresAt: Date().addingTimeInterval(86400), revokedAt: Date()
            ).save(on: app.db)

            let archivedList = PortfolioList(userId: userId, name: "Old plan")
            archivedList.archivedAt = Date()
            try await archivedList.save(on: app.db)
            try await RetirementPlanRecord(
                portfolioId: archivedList.requireID(), ruleVersion: "v1", inputJSON: "{}"
            ).save(on: app.db)

            let keys: Set = ["craft.thesis", "social.first_post", "social.popular_post", "learn.mcp", "plan.retirement"]
            let values = try await AchievementMetrics.measure(userId: userId, keys: keys, ctx: context(app))
            #expect(values["craft.thesis"] == 1)
            #expect(values["social.first_post"] == 1)
            #expect(values["social.popular_post"] == 12)
            #expect(values["learn.mcp"] == 0)
            #expect(values["plan.retirement"] == 0)
            #expect(Set(values.keys) == keys)
        }
    }

    @Test("Every catalogue key measures without throwing and unknown keys are ignored")
    func everyKeyMeasures() async throws {
        try await withApp { app in
            let user = try await register(app, "every")
            var keys = Set(AchievementCatalogue.all.map(\.key))
            keys.insert("no.such_key")
            let values = try await AchievementMetrics.measure(userId: user.userId, keys: keys, ctx: context(app))
            #expect(values["no.such_key"] == nil)
            for definition in AchievementCatalogue.all {
                #expect(values[definition.key] != nil, "missing \(definition.key)")
            }
            #expect(values["hidden.founding_member"] == 1)
            #expect(values["social.first_post"] == 0)
        }
    }

    @Test("Founding member is limited to the earliest users")
    func foundingMember() async throws {
        try await withApp { app in
            let first = try await register(app, "founder1")
            let second = try await register(app, "founder2")
            let previous = AchievementMetrics.foundingLimit
            AchievementMetrics.foundingLimit = 1
            defer { AchievementMetrics.foundingLimit = previous }

            let keys: Set = ["hidden.founding_member"]
            let firstValues = try await AchievementMetrics.measure(userId: first.userId, keys: keys, ctx: context(app))
            let secondValues = try await AchievementMetrics.measure(userId: second.userId, keys: keys, ctx: context(app))
            #expect(firstValues["hidden.founding_member"] == 1)
            #expect(secondValues["hidden.founding_member"] == 0)
        }
    }

    private func recap(_ userId: UUID, kind: String = "month", key: String, opened: Bool) -> RecapRecord {
        let record = RecapRecord()
        record.userId = userId
        record.periodKind = kind
        record.periodKey = key
        record.payload = "{}"
        record.schemaVersion = 1
        record.generatedAt = Date()
        record.openedAt = opened ? Date() : nil
        return record
    }

    @Test("Recap streak is the longest run of consecutive opened monthly recaps")
    func recapStreak() async throws {
        try await withApp { app in
            let steady = try await register(app, "recap1")
            for key in ["2025-12", "2026-01", "2026-02"] {
                try await recap(steady.userId, key: key, opened: true).save(on: app.db)
            }
            // A yearly recap is not a month and doesn't extend the run.
            try await recap(steady.userId, kind: "year", key: "2025", opened: true).save(on: app.db)

            let gappy = try await register(app, "recap2")
            for key in ["2026-01", "2026-02", "2026-04"] {
                try await recap(gappy.userId, key: key, opened: true).save(on: app.db)
            }
            // Generated but never opened: breaks the run instead of joining it.
            try await recap(gappy.userId, key: "2026-03", opened: false).save(on: app.db)

            let keys: Set = ["discipline.recap_regular"]
            let steadyValues = try await AchievementMetrics.measure(userId: steady.userId, keys: keys, ctx: context(app))
            let gappyValues = try await AchievementMetrics.measure(userId: gappy.userId, keys: keys, ctx: context(app))
            #expect(steadyValues["discipline.recap_regular"] == 3)
            #expect(gappyValues["discipline.recap_regular"] == 2)
        }
    }

    @Test("Articles count distinct articles from the views the articles route writes")
    func articleViews() async throws {
        try await ArticleTestKit.withApp { app in
            let author = try await ArticleTestKit.member(app, "achm_author")
            let reader = try await ArticleTestKit.member(app, "achm_reader")
            let first = try await ArticleTestKit.publish(app, as: author)
            let second = try await ArticleTestKit.publish(app, as: author, ArticleTestKit.input(title: "A second look at NextDecade"))

            // The real writer, so the viewer key is whatever it builds.
            for code in [first.article.code, first.article.code, second.article.code] {
                let reply = try await ArticleTestKit.send(app, .POST, "v1/articles/\(code)/view", as: reader)
                #expect(reply.status == .noContent)
            }
            // The route counts one row per viewer per day; add a second day for the
            // first article under the key the route wrote.
            let firstId = first.article.id
            let written = try #require(try await ArticleView.query(on: app.db).filter(\.$articleId == firstId).first())
            let laterDay = ArticleView()
            laterDay.articleId = written.articleId
            laterDay.viewerKey = written.viewerKey
            laterDay.day = "2000-01-01"
            try await laterDay.save(on: app.db)
            #expect(try await ArticleView.query(on: app.db).count() == 3)

            let keys: Set = ["learn.articles"]
            let readerValues = try await AchievementMetrics.measure(userId: reader.userId, keys: keys, ctx: context(app))
            let authorValues = try await AchievementMetrics.measure(userId: author.userId, keys: keys, ctx: context(app))
            #expect(readerValues["learn.articles"] == 2)
            #expect(authorValues["learn.articles"] == 0)
        }
    }

    @Test("No snapshots means every performance key is 0")
    func performanceWithoutSnapshots() async throws {
        try await withApp { app in
            let user = try await register(app, "perf")
            let keys: Set = ["perf.positive_year", "perf.beat_benchmark", "perf.comeback"]
            let values = try await AchievementMetrics.measure(userId: user.userId, keys: keys, ctx: context(app))
            #expect(values == ["perf.positive_year": 0, "perf.beat_benchmark": 0, "perf.comeback": 0])
        }
    }
}

extension AchievementMetricsTests {
    /// The performance predicates behind `perf.*`, on hand-built index series.
    /// Nested so `--filter AchievementMetricsTests` runs them too.
    @Suite("Achievement performance")
    struct Performance {
        private var utc: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
            return calendar
        }

        private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
            utc.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
        }

        /// Evenly spaced daily values from `from` to `to`, moving linearly from `start` to `end`.
        private func series(from: Date, to: Date, start: Double, end: Double) -> [(day: Date, value: Double)] {
            let days = utc.dateComponents([.day], from: from, to: to).day ?? 0
            return (0 ... days).map { offset in
                let day = PortfolioSnapshotValuator.addDays(from, days: offset)
                let value = start + (end - start) * Double(offset) / Double(max(days, 1))
                return (day, value)
            }
        }

        @Test("A positive year needs the whole year covered")
        func positiveYearNeedsFullCoverage() {
            let fullRising = series(from: date(2025, 1, 3), to: date(2025, 12, 30), start: 1.0, end: 1.2)
            #expect(AchievementPerformance.hasPositiveYear(fullRising, calendar: utc))

            let lateStart = series(from: date(2025, 3, 1), to: date(2025, 12, 30), start: 1.0, end: 1.2)
            #expect(!AchievementPerformance.hasPositiveYear(lateStart, calendar: utc))

            let fullFalling = series(from: date(2025, 1, 3), to: date(2025, 12, 30), start: 1.0, end: 0.9)
            #expect(!AchievementPerformance.hasPositiveYear(fullFalling, calendar: utc))
        }

        @Test("Beating the benchmark compares trailing-year returns")
        func beatBenchmark() {
            let asOf = date(2026, 10, 1)
            let yearAgo = PortfolioSnapshotValuator.addDays(asOf, days: -365)
            let spy = series(from: yearAgo, to: asOf, start: 100, end: 108).map { (day: $0.day, close: $0.value) }

            let strong = series(from: yearAgo, to: asOf, start: 1.0, end: 1.12)
            #expect(AchievementPerformance.beatBenchmark(strong, benchmark: spy, asOf: asOf))

            let weak = series(from: yearAgo, to: asOf, start: 1.0, end: 1.05)
            #expect(!AchievementPerformance.beatBenchmark(weak, benchmark: spy, asOf: asOf))

            let short = series(from: PortfolioSnapshotValuator.addDays(asOf, days: -200), to: asOf, start: 1.0, end: 1.5)
            #expect(!AchievementPerformance.beatBenchmark(short, benchmark: spy, asOf: asOf))

            #expect(!AchievementPerformance.beatBenchmark(strong, benchmark: [], asOf: asOf))
        }

        @Test("A comeback is a 10% drawdown later recovered to the peak")
        func comeback() {
            let start = date(2026, 1, 5)
            let path = { (values: [Double]) in
                values.enumerated().map { (day: PortfolioSnapshotValuator.addDays(start, days: $0.offset), value: $0.element) }
            }
            #expect(AchievementPerformance.hasComeback(path([1.0, 0.89, 1.01])))
            #expect(!AchievementPerformance.hasComeback(path([1.0, 0.92, 1.05])))
            #expect(!AchievementPerformance.hasComeback(path([1.0, 0.85, 0.95])))
            #expect(!AchievementPerformance.hasComeback([]))
        }

        @Test("Buying more is a flow, so the index stays flat")
        func indexRemovesFlows() throws {
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
            let index = AchievementPerformance.index(points)
            #expect(index.count == 3)
            #expect(index.map(\.day) == points.map(\.day))
            #expect(abs(index[0].value - 1.0) < 1e-9)
            #expect(abs(index[1].value - 1.1) < 1e-9)
            #expect(abs(index[2].value - 1.1) < 1e-9)

            // Agrees with the leaderboard's time-weighted return over the same points.
            let percent = try #require(LeaderboardReturns.timeWeightedPercent(points, periodStart: day(0)))
            #expect(abs((index[2].value - 1) * 100 - percent) < 0.01)
            #expect(AchievementPerformance.index([]).isEmpty)
        }
    }
}
