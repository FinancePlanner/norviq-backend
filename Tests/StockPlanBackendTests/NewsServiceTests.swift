import Fluent
import Foundation
@testable import StockPlanBackend
import Testing
import Vapor

@Suite("NewsService Tests", .serialized)
struct NewsServiceTests {
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

    private func createUser(email: String, on db: any Database) async throws -> User {
        let user = User(email: email, passwordHash: "test-hash")
        try await user.save(on: db)
        return user
    }

    private func makeRequest(
        symbol: String = "AAPL",
        headline: String = "Apple beats estimates",
        source: String? = "Reuters",
        url: String? = "https://example.com/news/apple",
        summary: String? = "Quarterly earnings beat.",
        publishedAt: String? = "2026-02-11T12:30:00Z"
    ) -> NewsItemRequest {
        NewsItemRequest(
            symbol: symbol,
            headline: headline,
            source: source,
            url: url,
            summary: summary,
            publishedAt: publishedAt
        )
    }

    private func parseISO8601(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) {
            return date
        }

        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        return withoutFractional.date(from: raw)
    }

    @Test("create() returns NewsItemResponse and persists")
    func createReturnsResponseAndPersists() async throws {
        try await withApp { app in
            let user = try await createUser(email: "news-create@example.com", on: app.db)
            let userId = try user.requireID()
            let service = DefaultNewsService()

            let response = try await service.create(
                payload: makeRequest(symbol: "  aapl  "),
                userId: userId,
                on: app.db
            )

            #expect(UUID(uuidString: response.id) != nil)
            #expect(response.symbol == "AAPL")
            #expect(response.headline == "Apple beats estimates")
            #expect(response.source == "Reuters")
            #expect(response.url == "https://example.com/news/apple")
            #expect(response.summary == "Quarterly earnings beat.")
            #expect(parseISO8601(response.publishedAt) != nil)

            let models = try await NewsItem.query(on: app.db)
                .filter(\.$userId == userId)
                .all()
            #expect(models.count == 1)
            #expect(models.first?.symbol == "AAPL")
        }
    }

    @Test("create() defaults publishedAt when omitted")
    func createDefaultsPublishedAt() async throws {
        try await withApp { app in
            let user = try await createUser(email: "news-default-date@example.com", on: app.db)
            let userId = try user.requireID()
            let service = DefaultNewsService()

            let before = Date()
            let response = try await service.create(
                payload: makeRequest(publishedAt: nil),
                userId: userId,
                on: app.db
            )
            let after = Date()

            guard let publishedAt = parseISO8601(response.publishedAt) else {
                #expect(Bool(false), "Expected valid ISO8601 publishedAt")
                return
            }

            #expect(publishedAt >= before.addingTimeInterval(-2))
            #expect(publishedAt <= after.addingTimeInterval(2))
        }
    }

    @Test("list() is user scoped and supports symbol filter")
    func listIsUserScopedAndFiltered() async throws {
        try await withApp { app in
            let service = DefaultNewsService()
            let user1 = try await createUser(email: "news-list-1@example.com", on: app.db)
            let user2 = try await createUser(email: "news-list-2@example.com", on: app.db)
            let user1Id = try user1.requireID()
            let user2Id = try user2.requireID()

            _ = try await service.create(payload: makeRequest(symbol: "AAPL"), userId: user1Id, on: app.db)
            _ = try await service.create(payload: makeRequest(symbol: "MSFT"), userId: user1Id, on: app.db)
            _ = try await service.create(payload: makeRequest(symbol: "AAPL"), userId: user2Id, on: app.db)

            let user1All = try await service.list(userId: user1Id, symbol: nil, on: app.db)
            #expect(user1All.count == 2)
            #expect(Set(user1All.map(\.symbol)) == Set(["AAPL", "MSFT"]))

            let user1Filtered = try await service.list(userId: user1Id, symbol: "  aapl ", on: app.db)
            #expect(user1Filtered.count == 1)
            #expect(user1Filtered.first?.symbol == "AAPL")

            let user2All = try await service.list(userId: user2Id, symbol: nil, on: app.db)
            #expect(user2All.count == 1)
            #expect(user2All.first?.symbol == "AAPL")
        }
    }

    @Test("get() throws notFound when missing")
    func getNotFoundForMissingId() async throws {
        try await withApp { app in
            let service = DefaultNewsService()
            let user = try await createUser(email: "news-get-missing@example.com", on: app.db)
            let userId = try user.requireID()

            do {
                _ = try await service.get(id: UUID(), userId: userId, on: app.db)
                #expect(Bool(false), "Expected notFound")
            } catch NewsServiceError.notFound {
                #expect(Bool(true))
            }
        }
    }

    @Test("get() is user scoped")
    func getIsUserScoped() async throws {
        try await withApp { app in
            let service = DefaultNewsService()
            let owner = try await createUser(email: "news-get-owner@example.com", on: app.db)
            let other = try await createUser(email: "news-get-other@example.com", on: app.db)
            let ownerId = try owner.requireID()
            let otherId = try other.requireID()

            let created = try await service.create(payload: makeRequest(symbol: "AAPL"), userId: ownerId, on: app.db)
            guard let newsId = UUID(uuidString: created.id) else {
                #expect(Bool(false), "Expected UUID id")
                return
            }

            do {
                _ = try await service.get(id: newsId, userId: otherId, on: app.db)
                #expect(Bool(false), "Expected notFound for non-owner")
            } catch NewsServiceError.notFound {
                #expect(Bool(true))
            }
        }
    }

    @Test("update() persists changes")
    func updatePersistsChanges() async throws {
        try await withApp { app in
            let service = DefaultNewsService()
            let user = try await createUser(email: "news-update@example.com", on: app.db)
            let userId = try user.requireID()

            let created = try await service.create(payload: makeRequest(symbol: "AAPL"), userId: userId, on: app.db)
            guard let newsId = UUID(uuidString: created.id) else {
                #expect(Bool(false), "Expected UUID id")
                return
            }

            let updated = try await service.update(
                id: newsId,
                payload: makeRequest(
                    symbol: " msft ",
                    headline: "Microsoft raises guidance",
                    source: "Bloomberg",
                    url: "https://example.com/news/msft",
                    summary: "Guidance improved for next quarter.",
                    publishedAt: "2026-02-10T09:15:00Z"
                ),
                userId: userId,
                on: app.db
            )

            #expect(updated.symbol == "MSFT")
            #expect(updated.headline == "Microsoft raises guidance")
            #expect(updated.source == "Bloomberg")
            #expect(updated.url == "https://example.com/news/msft")
            #expect(updated.summary == "Guidance improved for next quarter.")
            #expect(parseISO8601(updated.publishedAt) != nil)

            let model = try await NewsItem.query(on: app.db)
                .filter(\.$id == newsId)
                .filter(\.$userId == userId)
                .first()
            #expect(model?.symbol == "MSFT")
            #expect(model?.headline == "Microsoft raises guidance")
        }
    }

    @Test("delete() is user scoped and removes item")
    func deleteIsUserScopedAndRemoves() async throws {
        try await withApp { app in
            let service = DefaultNewsService()
            let owner = try await createUser(email: "news-delete-owner@example.com", on: app.db)
            let other = try await createUser(email: "news-delete-other@example.com", on: app.db)
            let ownerId = try owner.requireID()
            let otherId = try other.requireID()

            let created = try await service.create(payload: makeRequest(symbol: "AAPL"), userId: ownerId, on: app.db)
            guard let newsId = UUID(uuidString: created.id) else {
                #expect(Bool(false), "Expected UUID id")
                return
            }

            do {
                try await service.delete(id: newsId, userId: otherId, on: app.db)
                #expect(Bool(false), "Expected notFound for non-owner delete")
            } catch NewsServiceError.notFound {
                #expect(Bool(true))
            }

            try await service.delete(id: newsId, userId: ownerId, on: app.db)

            let found = try await NewsItem.query(on: app.db)
                .filter(\.$id == newsId)
                .filter(\.$userId == ownerId)
                .first()
            #expect(found == nil)
        }
    }

    @Test("create() validates symbol")
    func createValidatesSymbol() async throws {
        try await withApp { app in
            let service = DefaultNewsService()
            let user = try await createUser(email: "news-validate-symbol@example.com", on: app.db)
            let userId = try user.requireID()

            do {
                _ = try await service.create(payload: makeRequest(symbol: "   "), userId: userId, on: app.db)
                #expect(Bool(false), "Expected invalidSymbol")
            } catch NewsServiceError.invalidSymbol {
                #expect(Bool(true))
            }
        }
    }

    @Test("create() validates headline")
    func createValidatesHeadline() async throws {
        try await withApp { app in
            let service = DefaultNewsService()
            let user = try await createUser(email: "news-validate-headline@example.com", on: app.db)
            let userId = try user.requireID()

            do {
                _ = try await service.create(payload: makeRequest(headline: "   "), userId: userId, on: app.db)
                #expect(Bool(false), "Expected invalidHeadline")
            } catch NewsServiceError.invalidHeadline {
                #expect(Bool(true))
            }
        }
    }

    @Test("create() validates url")
    func createValidatesURL() async throws {
        try await withApp { app in
            let service = DefaultNewsService()
            let user = try await createUser(email: "news-validate-url@example.com", on: app.db)
            let userId = try user.requireID()

            do {
                _ = try await service.create(payload: makeRequest(url: "not a valid url"), userId: userId, on: app.db)
                #expect(Bool(false), "Expected invalidURL")
            } catch NewsServiceError.invalidURL {
                #expect(Bool(true))
            }
        }
    }

    @Test("create() validates publishedAt")
    func createValidatesPublishedAt() async throws {
        try await withApp { app in
            let service = DefaultNewsService()
            let user = try await createUser(email: "news-validate-published-at@example.com", on: app.db)
            let userId = try user.requireID()

            do {
                _ = try await service.create(payload: makeRequest(publishedAt: "2026/02/11"), userId: userId, on: app.db)
                #expect(Bool(false), "Expected invalidPublishedAt")
            } catch NewsServiceError.invalidPublishedAt {
                #expect(Bool(true))
            }
        }
    }
}
