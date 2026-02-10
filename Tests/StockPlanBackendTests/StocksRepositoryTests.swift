@testable import StockPlanBackend
import Fluent
import Testing
import Vapor

@Suite("StocksRepository Tests", .serialized)
struct StocksRepositoryTests {
    private func withApp(_ test: (Application) async throws -> ()) async throws {
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

    private func makePayload(
        symbol: String = "AAPL",
        shares: Double = 1,
        buyPrice: Double = 100,
        buyDate: String = "2024-01-01",
        notes: String? = nil
    ) -> StockRequest {
        StockRequest(symbol: symbol, shares: shares, buyPrice: buyPrice, buyDate: buyDate, notes: notes)
    }

    private func formatISODateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    @Test("create() normalizes symbol and persists")
    func createNormalizesSymbol() async throws {
        try await withApp { app in
            let repo = DatabaseStocksRepository()
            let user = try await createUser(email: "repo-create@example.com", on: app.db)
            let userId = try user.requireID()

            let payload = makePayload(symbol: "  aapl  ", shares: 2.5, buyPrice: 123.45, buyDate: "2024-02-03", notes: "note")
            let created = try await repo.create(payload: payload, userId: userId, on: app.db)

            #expect(created.userId == userId)
            #expect(created.symbol == "AAPL")
            #expect(created.shares == 2.5)
            #expect(created.buyPrice == 123.45)
            #expect(formatISODateOnly(created.buyDate) == "2024-02-03")
            #expect(created.notes == "note")

            let fetched = try await repo.find(id: try created.requireID(), userId: userId, on: app.db)
            #expect(fetched?.symbol == "AAPL")
        }
    }

    @Test("create() rejects invalid buyDate")
    func createRejectsInvalidBuyDate() async throws {
        try await withApp { app in
            let repo = DatabaseStocksRepository()
            let user = try await createUser(email: "repo-invalid-date@example.com", on: app.db)
            let userId = try user.requireID()

            do {
                _ = try await repo.create(payload: makePayload(symbol: "AAPL", buyDate: "2024/01/01"), userId: userId, on: app.db)
                #expect(Bool(false), "Expected badRequest for invalid buyDate")
            } catch let abort as Abort {
                #expect(abort.status == .badRequest)
            }
        }
    }

    @Test("find(id:) is user scoped")
    func findByIdIsUserScoped() async throws {
        try await withApp { app in
            let repo = DatabaseStocksRepository()
            let user1 = try await createUser(email: "repo-scope-1@example.com", on: app.db)
            let user2 = try await createUser(email: "repo-scope-2@example.com", on: app.db)
            let user1Id = try user1.requireID()
            let user2Id = try user2.requireID()

            let created = try await repo.create(payload: makePayload(symbol: "MSFT"), userId: user1Id, on: app.db)
            let stockId = try created.requireID()

            let foundForOwner = try await repo.find(id: stockId, userId: user1Id, on: app.db)
            #expect(foundForOwner != nil)

            let foundForOtherUser = try await repo.find(id: stockId, userId: user2Id, on: app.db)
            #expect(foundForOtherUser == nil)
        }
    }

    @Test("find(symbol:) normalizes and is user scoped")
    func findBySymbolNormalizesAndScopes() async throws {
        try await withApp { app in
            let repo = DatabaseStocksRepository()
            let user1 = try await createUser(email: "repo-symbol-1@example.com", on: app.db)
            let user2 = try await createUser(email: "repo-symbol-2@example.com", on: app.db)
            let user1Id = try user1.requireID()
            let user2Id = try user2.requireID()

            _ = try await repo.create(payload: makePayload(symbol: "AAPL"), userId: user1Id, on: app.db)
            _ = try await repo.create(payload: makePayload(symbol: "AAPL"), userId: user2Id, on: app.db)

            let found1 = try await repo.find(symbol: "  aapl  ", userId: user1Id, on: app.db)
            #expect(found1?.userId == user1Id)
        }
    }

    @Test("list() returns only user's stocks")
    func listIsUserScoped() async throws {
        try await withApp { app in
            let repo = DatabaseStocksRepository()
            let user1 = try await createUser(email: "repo-list-1@example.com", on: app.db)
            let user2 = try await createUser(email: "repo-list-2@example.com", on: app.db)
            let user1Id = try user1.requireID()
            let user2Id = try user2.requireID()

            _ = try await repo.create(payload: makePayload(symbol: "AAPL"), userId: user1Id, on: app.db)
            _ = try await repo.create(payload: makePayload(symbol: "MSFT"), userId: user1Id, on: app.db)
            _ = try await repo.create(payload: makePayload(symbol: "NVDA"), userId: user2Id, on: app.db)

            let user1Stocks = try await repo.list(userId: user1Id, on: app.db)
            #expect(Set(user1Stocks.map(\.symbol)) == Set(["AAPL", "MSFT"]))

            let user2Stocks = try await repo.list(userId: user2Id, on: app.db)
            #expect(user2Stocks.map(\.symbol) == ["NVDA"])
        }
    }

    @Test("update() is user scoped")
    func updateIsUserScoped() async throws {
        try await withApp { app in
            let repo = DatabaseStocksRepository()
            let user1 = try await createUser(email: "repo-update-1@example.com", on: app.db)
            let user2 = try await createUser(email: "repo-update-2@example.com", on: app.db)
            let user1Id = try user1.requireID()
            let user2Id = try user2.requireID()

            let created = try await repo.create(payload: makePayload(symbol: "AAPL", shares: 1), userId: user1Id, on: app.db)
            let stockId = try created.requireID()

            let updatedByOther = try await repo.update(id: stockId, payload: makePayload(symbol: "AAPL", shares: 999), userId: user2Id, on: app.db)
            #expect(updatedByOther == nil)

            let updatedByOwner = try await repo.update(id: stockId, payload: makePayload(symbol: "AAPL", shares: 3), userId: user1Id, on: app.db)
            #expect(updatedByOwner?.shares == 3)
        }
    }

    @Test("delete() is user scoped")
    func deleteIsUserScoped() async throws {
        try await withApp { app in
            let repo = DatabaseStocksRepository()
            let user1 = try await createUser(email: "repo-delete-1@example.com", on: app.db)
            let user2 = try await createUser(email: "repo-delete-2@example.com", on: app.db)
            let user1Id = try user1.requireID()
            let user2Id = try user2.requireID()

            let created = try await repo.create(payload: makePayload(symbol: "AAPL"), userId: user1Id, on: app.db)
            let stockId = try created.requireID()

            let deletedByOther = try await repo.delete(id: stockId, userId: user2Id, on: app.db)
            #expect(deletedByOther == false)

            let deletedByOwner = try await repo.delete(id: stockId, userId: user1Id, on: app.db)
            #expect(deletedByOwner == true)

            let found = try await repo.find(id: stockId, userId: user1Id, on: app.db)
            #expect(found == nil)
        }
    }
}
