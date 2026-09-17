import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

/// Stub aggregator: returns a canned document and records what it was asked.
final class StubFeedsClient: FeedsClient, @unchecked Sendable {
    var document: JSONFeedDocument
    var candidates: [FeedCandidate] = []
    var discoverError: (any Error)?
    private(set) var itemsCalls: [[String]] = []
    private(set) var discoverCalls: [String] = []

    init(document: JSONFeedDocument) {
        self.document = document
    }

    func items(feeds: [String], limit _: Int, on _: Request) async throws -> JSONFeedDocument {
        itemsCalls.append(feeds)
        return document
    }

    func discover(url: String, on _: Request) async throws -> [FeedCandidate] {
        discoverCalls.append(url)
        if let discoverError {
            throw discoverError
        }
        return candidates
    }
}

@Suite("News ticker mapping")
struct NewsTickerMappingTests {
    private func doc(stale: [String] = []) throws -> JSONFeedDocument {
        let json = """
        {"version":"https://jsonfeed.org/version/1.1","title":"Merged timeline","items":[
          {"id":"a","url":"https://x/a","title":"A","date_published":"2026-09-17T11:00:00Z","_feeds":{"source_name":"CNBC","source_url":"https://cnbc.com","feed_url":"https://f/a"}},
          {"id":"b","url":"https://x/b","title":"B","date_published":"2026-09-17T10:00:00Z","_feeds":{"source_name":"Fed","feed_url":"https://f/b"}}],
         "_feeds":{"warming":[],"stale":\(stale.map { "\"\($0)\"" }),"generated_at":"2026-09-17T12:00:00Z"}}
        """
        return try JSONFeedDocument.decode(from: Data(json.utf8))
    }

    @Test("Maps items to ticker DTOs with ISO dates and stale flag")
    func maps() throws {
        let r = try NewsTickerMapping.response(from: doc(stale: ["https://f/b"]), enabled: true, now: Date(timeIntervalSince1970: 1_789_646_400))
        #expect(r.enabled)
        #expect(r.stale)
        #expect(r.items.map(\.id) == ["a", "b"])
        #expect(r.items[0].source == "CNBC")
        #expect(r.items[0].sourceUrl == "https://cnbc.com")
        #expect(r.items[0].publishedAt == "2026-09-17T11:00:00Z")
        #expect(r.generatedAt == "2026-09-17T12:00:00Z")
    }

    @Test("Curated and user feeds merge in order without duplicates, capped at the aggregator's per-call limit")
    func feedListMerge() {
        let merged = NewsTickerMapping.feedList(curated: ["https://a", "https://b"], user: ["https://b", "https://c"])
        #expect(merged == ["https://a", "https://b", "https://c"])
        let many = (0 ..< 40).map { "https://f/\($0)" }
        #expect(NewsTickerMapping.feedList(curated: many, user: []).count == 25)
    }
}

@Suite("News ticker service", .serialized)
struct NewsTickerServiceTests {
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

    private func emptyDoc() throws -> JSONFeedDocument {
        try JSONFeedDocument.decode(from: Data(#"{"version":"https://jsonfeed.org/version/1.1","title":"t","items":[],"_feeds":{"warming":[],"stale":[],"generated_at":"2026-09-17T12:00:00Z"}}"#.utf8))
    }

    @Test("Settings default to enabled and persist updates")
    func settings() async throws {
        try await withApp { app in
            let user = User(email: "ticker-settings@example.com", passwordHash: "x")
            try await user.save(on: app.db)
            let service = try DefaultNewsTickerService(client: StubFeedsClient(document: emptyDoc()), curatedFeeds: [])
            #expect(try await service.settings(userId: user.requireID(), on: app.db).enabled == true)
            let updated = try await service.updateSettings(userId: user.requireID(), enabled: false, on: app.db)
            #expect(updated.enabled == false)
            #expect(try await service.settings(userId: user.requireID(), on: app.db).enabled == false)
        }
    }

    @Test("Disabled ticker short-circuits without calling the aggregator")
    func disabledShortCircuits() async throws {
        try await withApp { app in
            let user = User(email: "ticker-disabled@example.com", passwordHash: "x")
            try await user.save(on: app.db)
            let stub = try StubFeedsClient(document: emptyDoc())
            let service = DefaultNewsTickerService(client: stub, curatedFeeds: ["https://a/rss"])
            _ = try await service.updateSettings(userId: user.requireID(), enabled: false, on: app.db)
            let req = Request(application: app, on: app.eventLoopGroup.next())
            let r = try await service.ticker(userId: user.requireID(), limit: 20, on: req)
            #expect(r.enabled == false)
            #expect(r.items.isEmpty)
            #expect(stub.itemsCalls.isEmpty)
        }
    }

    @Test("Adding a feed discovers it, stores the first candidate, rejects duplicates and enforces the cap")
    func addFeed() async throws {
        try await withApp { app in
            let user = User(email: "ticker-feeds@example.com", passwordHash: "x")
            try await user.save(on: app.db)
            let stub = try StubFeedsClient(document: emptyDoc())
            stub.candidates = [FeedCandidate(url: "https://site/feed.xml", type: "rss", title: "Site")]
            let service = DefaultNewsTickerService(client: stub, curatedFeeds: [], maxUserFeeds: 2)
            let req = Request(application: app, on: app.eventLoopGroup.next())
            let added = try await service.addFeed(userId: user.requireID(), url: "https://site", on: req)
            #expect(added.url == "https://site/feed.xml")
            #expect(added.title == "Site")
            #expect(stub.discoverCalls == ["https://site"])
            await #expect(throws: Abort.self) {
                _ = try await service.addFeed(userId: user.requireID(), url: "https://site", on: req)
            }
            stub.candidates = [FeedCandidate(url: "https://two/feed", type: "atom", title: "Two")]
            _ = try await service.addFeed(userId: user.requireID(), url: "https://two", on: req)
            stub.candidates = [FeedCandidate(url: "https://three/feed", type: "atom", title: "Three")]
            await #expect(throws: Abort.self) {
                _ = try await service.addFeed(userId: user.requireID(), url: "https://three", on: req)
            }
            let list = try await service.listFeeds(userId: user.requireID(), on: app.db)
            #expect(list.feeds.map(\.url) == ["https://site/feed.xml", "https://two/feed"])
            #expect(list.maxFeeds == 2)
            try await service.removeFeed(userId: user.requireID(), feedId: UUID(uuidString: list.feeds[0].id)!, on: app.db)
            #expect(try await service.listFeeds(userId: user.requireID(), on: app.db).feeds.count == 1)
        }
    }

    @Test("Ticker asks the aggregator for curated plus the user's own feeds")
    func tickerUsesUserFeeds() async throws {
        try await withApp { app in
            let user = User(email: "ticker-merge@example.com", passwordHash: "x")
            try await user.save(on: app.db)
            let stub = try StubFeedsClient(document: emptyDoc())
            stub.candidates = [FeedCandidate(url: "https://mine/feed", type: "rss", title: "Mine")]
            let service = DefaultNewsTickerService(client: stub, curatedFeeds: ["https://curated/rss"])
            let req = Request(application: app, on: app.eventLoopGroup.next())
            _ = try await service.addFeed(userId: user.requireID(), url: "https://mine", on: req)
            _ = try await service.ticker(userId: user.requireID(), limit: 20, on: req)
            #expect(stub.itemsCalls == [["https://curated/rss", "https://mine/feed"]])
        }
    }
}
