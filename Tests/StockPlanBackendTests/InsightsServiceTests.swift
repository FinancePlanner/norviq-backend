import Fluent
import Foundation
@testable import StockPlanBackend
import Testing
import Vapor

private struct StubInsightsProvider: InsightsProvider {
    var isEnabled: Bool {
        true
    }

    func fetchEvents(days _: Int, limit _: Int, on _: Request) async throws -> HermesEventsResponse {
        HermesEventsResponse(count: 2, events: [
            HermesEventDTO(
                eventId: "event-1",
                source: "x",
                sourceId: "post-1",
                topic: "Housing",
                observedAt: "2026-07-01T10:00:00+00:00",
                ingestedAt: "2026-07-01T10:05:00+00:00",
                payload: HermesEventPayload(title: "Housing cooling", summary: "Prices flat", url: "https://x.com/a/1", author: "Ana"),
                sentiment: HermesEventSentiment(label: "negative", score: -0.4)
            ),
            HermesEventDTO(
                eventId: "event-2",
                source: "x",
                sourceId: "post-2",
                topic: "Crypto",
                // Malformed legacy Hermes timestamp: offset plus trailing Z.
                observedAt: "2026-07-02T09:00:00+00:00Z",
                ingestedAt: nil,
                payload: HermesEventPayload(title: "BTC rally", summary: nil, url: nil, author: nil),
                sentiment: HermesEventSentiment(label: "positive", score: 0.7)
            ),
        ])
    }

    func fetchSummary(days: Int, on _: Request) async throws -> HermesSummaryResponse {
        HermesSummaryResponse(windowDays: days, totalEvents: 2, byTopic: ["Housing": 1, "Crypto": 1])
    }

    func fetchSentiment(topic: String?, days: Int, on _: Request) async throws -> HermesSentimentResponse {
        HermesSentimentResponse(
            topic: topic,
            windowDays: days,
            count: 10,
            labelCounts: ["positive": 6, "neutral": 3, "negative": 1],
            averageScore: 0.42,
            sampled: 10
        )
    }

    func fetchNetWorth(on _: Request) async throws -> HermesNetWorthResponse {
        HermesNetWorthResponse(
            latest: HermesNetWorthEntry(eventId: "nw-1", ingestedAt: "2026-07-03T08:00:00+00:00", value: 125_000),
            history: [HermesNetWorthEntry(eventId: "nw-0", ingestedAt: "2026-06-26T08:00:00+00:00", value: 120_000)]
        )
    }

    func fetchTickerPosts(symbol: String, days: Int, limit _: Int, on _: Request) async throws -> HermesTickerPostsResponse {
        HermesTickerPostsResponse(symbol: symbol, days: days, count: 1, posts: [
            HermesTickerPostDTO(
                eventId: "tweet-\(symbol)-1",
                author: "Notable Investor",
                authorHandle: "notable",
                text: "\(symbol) thesis: undervalued on AI demand.",
                url: "https://x.com/notable/status/1",
                sentiment: "bullish",
                sentimentScore: 0.8,
                confidence: 0.9,
                postedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
            ),
        ])
    }

    func health(on _: Request) async -> Bool {
        true
    }
}

@Suite("InsightsService Tests", .serialized)
struct InsightsServiceTests {
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

    private func makeService(trackedTickers: [String] = ["AMD"]) -> DefaultInsightsService {
        DefaultInsightsService(
            repo: DatabaseInsightsRepository(),
            provider: StubInsightsProvider(),
            trackedTickers: trackedTickers
        )
    }

    @Test("syncFromHermes persists events, snapshots, ticker posts, and net worth")
    func syncPersistsAll() async throws {
        try await withApp { app in
            let service = makeService()
            let req = Request(application: app, on: app.eventLoopGroup.next())

            let summary = try await service.syncFromHermes(on: req)

            #expect(summary.eventsInserted == 2)
            #expect(summary.tickerPostsInserted == 1)
            #expect(summary.netWorthInserted == 2)
            // 1 overall + 2 topics from the stub summary.
            #expect(summary.snapshotsUpserted == 3)

            let events = try await InsightEvent.query(on: app.db).all()
            #expect(events.count == 2)
            let cryptoEvent = events.first { $0.dedupeKey == "event-2" }
            // The malformed "+00:00Z" timestamp must still parse to a real date.
            #expect(cryptoEvent != nil)
            #expect(cryptoEvent?.observedAt != nil)
            #expect(cryptoEvent?.sentimentLabel == "positive")
        }
    }

    @Test("syncFromHermes is idempotent across repeated runs")
    func syncIsIdempotent() async throws {
        try await withApp { app in
            let service = makeService()
            let req = Request(application: app, on: app.eventLoopGroup.next())

            _ = try await service.syncFromHermes(on: req)
            let second = try await service.syncFromHermes(on: req)

            #expect(second.eventsInserted == 0)
            #expect(second.tickerPostsInserted == 0)
            #expect(second.netWorthInserted == 0)

            #expect(try await InsightEvent.query(on: app.db).count() == 2)
            #expect(try await TickerSentimentPost.query(on: app.db).count() == 1)
            #expect(try await NetWorthSnapshot.query(on: app.db).count() == 2)
            // Snapshots are upserts keyed per scope+window+day: still 3 rows.
            #expect(try await SentimentSnapshot.query(on: app.db).count() == 3)
        }
    }

    @Test("tickerSentiment aggregates persisted posts")
    func tickerSentimentAggregates() async throws {
        try await withApp { app in
            let service = makeService()
            let req = Request(application: app, on: app.eventLoopGroup.next())
            _ = try await service.syncFromHermes(on: req)

            let response = try await service.tickerSentiment(symbol: "AMD", days: 14, limit: 20, on: app.db)

            #expect(response.symbol == "AMD")
            #expect(response.aggregate.postCount == 1)
            #expect(response.aggregate.label == "bullish")
            #expect(response.posts.first?.authorHandle == "notable")
            #expect(response.posts.first?.sentimentLabel == "bullish")
        }
    }

    @Test("sentiment throws notFound before the first sync")
    func sentimentNotFoundBeforeSync() async throws {
        try await withApp { app in
            let service = makeService()
            await #expect(throws: Abort.self) {
                _ = try await service.sentiment(topic: nil, on: app.db)
            }
        }
    }

    @Test("disabled provider refuses sync and reports disabled")
    func disabledProviderRefusesSync() async throws {
        try await withApp { app in
            let service = DefaultInsightsService(
                repo: DatabaseInsightsRepository(),
                provider: DisabledInsightsProvider(),
                trackedTickers: []
            )
            #expect(service.isEnabled == false)

            let req = Request(application: app, on: app.eventLoopGroup.next())
            await #expect(throws: Abort.self) {
                _ = try await service.syncFromHermes(on: req)
            }
        }
    }

    @Test("parseHermesTimestamp accepts offset, malformed offset+Z, and Z forms")
    func timestampParsing() {
        #expect(parseHermesTimestamp("2026-07-03T22:13:45+00:00") != nil)
        #expect(parseHermesTimestamp("2026-07-03T22:13:45+00:00Z") != nil)
        #expect(parseHermesTimestamp("2026-07-03T22:13:45Z") != nil)
        #expect(parseHermesTimestamp("not-a-date") == nil)
        #expect(parseHermesTimestamp(nil) == nil)
    }
}
