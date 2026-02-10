@testable import StockPlanBackend
import Fluent
import Testing
import Vapor

@Suite("StockService Tests", .serialized)
struct StockServiceTests {
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

    @Test("create() returns StockResponse and persists")
    func createReturnsResponse() async throws {
        try await withApp { app in
            let user = try await createUser(email: "service-create@example.com", on: app.db)
            let userId = try user.requireID()

            let service = StockServiceImpl(repo: DatabaseStocksRepository())
            let response = try await service.create(payload: makePayload(symbol: "  aapl  ", shares: 2, buyPrice: 10, buyDate: "2024-05-06"), userId: userId, on: app.db)

            #expect(UUID(uuidString: response.id) != nil)
            #expect(response.symbol == "AAPL")
            #expect(response.shares == 2)
            #expect(response.buyPrice == 10)
            #expect(response.buyDate == "2024-05-06")

            let models = try await Stock.query(on: app.db)
                .filter(\.$userId == userId)
                .all()
            #expect(models.count == 1)
        }
    }

    @Test("create() validates symbol")
    func createValidatesSymbol() async throws {
        try await withApp { app in
            let user = try await createUser(email: "service-create-validate@example.com", on: app.db)
            let userId = try user.requireID()
            let service = StockServiceImpl(repo: DatabaseStocksRepository())

            do {
                _ = try await service.create(payload: makePayload(symbol: "   "), userId: userId, on: app.db)
                #expect(Bool(false), "Expected invalidSymbol")
            } catch StockServiceError.invalidSymbol {
                #expect(Bool(true))
            }
        }
    }

    @Test("get(id:) throws notFound when missing")
    func getByIdNotFound() async throws {
        try await withApp { app in
            let user = try await createUser(email: "service-get-missing@example.com", on: app.db)
            let userId = try user.requireID()
            let service = StockServiceImpl(repo: DatabaseStocksRepository())

            do {
                _ = try await service.get(id: UUID(), userId: userId, on: app.db)
                #expect(Bool(false), "Expected notFound")
            } catch StockServiceError.notFound {
                #expect(Bool(true))
            }
        }
    }

    @Test("update() throws notFound when missing")
    func updateNotFound() async throws {
        try await withApp { app in
            let user = try await createUser(email: "service-update-missing@example.com", on: app.db)
            let userId = try user.requireID()
            let service = StockServiceImpl(repo: DatabaseStocksRepository())

            do {
                _ = try await service.update(id: UUID(), payload: makePayload(symbol: "AAPL"), userId: userId, on: app.db)
                #expect(Bool(false), "Expected notFound")
            } catch StockServiceError.notFound {
                #expect(Bool(true))
            }
        }
    }

    @Test("delete() throws notFound when missing")
    func deleteNotFound() async throws {
        try await withApp { app in
            let user = try await createUser(email: "service-delete-missing@example.com", on: app.db)
            let userId = try user.requireID()
            let service = StockServiceImpl(repo: DatabaseStocksRepository())

            do {
                try await service.delete(id: UUID(), userId: userId, on: app.db)
                #expect(Bool(false), "Expected notFound")
            } catch StockServiceError.notFound {
                #expect(Bool(true))
            }
        }
    }

    @Test("get(symbol:) returns StockResponse")
    func getBySymbol() async throws {
        try await withApp { app in
            let user = try await createUser(email: "service-get-symbol@example.com", on: app.db)
            let userId = try user.requireID()

            let repo = DatabaseStocksRepository()
            _ = try await repo.create(payload: makePayload(symbol: "MSFT", buyDate: "2024-03-04"), userId: userId, on: app.db)

            let service = StockServiceImpl(repo: repo)
            let response = try await service.get(symbol: "  msft  ", userId: userId, on: app.db)
            #expect(response.symbol == "MSFT")
            #expect(response.buyDate == "2024-03-04")
        }
    }
}
