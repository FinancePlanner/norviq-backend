import Fluent
@testable import StockPlanBackend
import Testing
import Vapor

@Suite("StockService Tests", .serialized)
struct StockServiceTests {
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

    private func makeRequest(_ app: Application) -> Request {
        Request(application: app, on: app.eventLoopGroup.next())
    }

    private func createManualAccount(userId: UUID, on db: any Database) async throws -> Account {
        let account = Account(
            userId: userId,
            externalId: "manual-\(userId.uuidString.lowercased())",
            broker: "manual",
            displayName: "Manual Cash Account",
            baseCurrency: "USD"
        )
        try await account.save(on: db)
        return account
    }

    private func makePayload(
        symbol: String = "AAPL",
        shares: Double = 1,
        buyPrice: Double = 100,
        buyDate: String = "2024-01-01",
        notes: String? = nil
    ) -> StockRequest {
        StockRequest(
            symbol: symbol, shares: shares, buyPrice: buyPrice, buyDate: buyDate, notes: notes
        )
    }

    private func makeValuationPayload(
        symbol: String = "AAPL",
        bearLow: Double = 10,
        bearHigh: Double = 15,
        baseLow: Double = 16,
        baseHigh: Double = 22,
        bullLow: Double = 23,
        bullHigh: Double = 30,
        rationale: String? = nil,
        targetDate: String? = "2026-12-31"
    ) -> StockValuationRequest {
        StockValuationRequest(
            symbol: symbol,
            bearCase: PriceRange(low: bearLow, high: bearHigh),
            baseCase: PriceRange(low: baseLow, high: baseHigh),
            bullCase: PriceRange(low: bullLow, high: bullHigh),
            rationale: rationale,
            targetDate: targetDate
        )
    }

    private func makeSellPayload(
        sharesToSell: Double = 1,
        sellPrice: Double = 150,
        sellDate: String = "2026-04-10"
    ) -> SellStockRequest {
        SellStockRequest(
            sharesToSell: sharesToSell,
            sellPrice: sellPrice,
            sellDate: sellDate
        )
    }

    @Test("create() returns StockResponse and persists")
    func createReturnsResponse() async throws {
        try await withApp { app in
            let user = try await createUser(email: "service-create@example.com", on: app.db)
            let userId = try user.requireID()

            let service = StockServiceImpl(repo: DatabaseStocksRepository(), req: makeRequest(app))
            let response = try await service.create(
                payload: makePayload(
                    symbol: "  aapl  ", shares: 2, buyPrice: 10, buyDate: "2024-05-06"
                ),
                userId: userId, on: app.db
            )

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

    @Test("create() merges existing symbol by adding shares and weighted average buyPrice")
    func createMergesExistingSymbol() async throws {
        try await withApp { app in
            let user = try await createUser(email: "service-merge@example.com", on: app.db)
            let userId = try user.requireID()

            let service = StockServiceImpl(repo: DatabaseStocksRepository(), req: makeRequest(app))

            let first = try await service.create(
                payload: makePayload(symbol: "AAPL", shares: 2, buyPrice: 10, buyDate: "2024-05-06"),
                userId: userId,
                on: app.db
            )

            let second = try await service.create(
                payload: makePayload(symbol: " aapl ", shares: 1, buyPrice: 20, buyDate: "2024-05-07"),
                userId: userId,
                on: app.db
            )

            #expect(UUID(uuidString: second.id) == UUID(uuidString: first.id))
            #expect(second.shares == 3)
            #expect(abs(second.buyPrice - (((2 * 10) + (1 * 20)) / 3)) < 0.001)
            #expect(second.buyDate == "2024-05-06")

            let models = try await Stock.query(on: app.db)
                .filter(\.$userId == userId)
                .all()
            #expect(models.count == 1)
        }
    }

    @Test("create() validates symbol")
    func createValidatesSymbol() async throws {
        try await withApp { app in
            let user = try await createUser(
                email: "service-create-validate@example.com", on: app.db
            )
            let userId = try user.requireID()
            let service = StockServiceImpl(repo: DatabaseStocksRepository(), req: makeRequest(app))

            do {
                _ = try await service.create(
                    payload: makePayload(symbol: "   "), userId: userId, on: app.db
                )
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
            let service = StockServiceImpl(repo: DatabaseStocksRepository(), req: makeRequest(app))

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
            let service = StockServiceImpl(repo: DatabaseStocksRepository(), req: makeRequest(app))

            do {
                _ = try await service.update(
                    id: UUID(), payload: makePayload(symbol: "AAPL"), userId: userId, on: app.db
                )
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
            let service = StockServiceImpl(repo: DatabaseStocksRepository(), req: makeRequest(app))

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
            _ = try await repo.create(
                payload: makePayload(symbol: "MSFT", buyDate: "2024-03-04"), userId: userId,
                on: app.db
            )

            let service = StockServiceImpl(repo: repo, req: makeRequest(app))
            let response = try await service.get(symbol: "  msft  ", userId: userId, on: app.db)
            #expect(response.symbol == "MSFT")
            #expect(response.buyDate == "2024-03-04")
        }
    }

    @Test("bulkCreate() returns all results")
    func bulkCreateReturnsResults() async throws {
        try await withApp { app in
            let user = try await createUser(email: "service-bulk-create@example.com", on: app.db)
            let userId = try user.requireID()

            let service = StockServiceImpl(repo: DatabaseStocksRepository(), req: makeRequest(app))
            let payloads = [
                makePayload(symbol: "AAPL", shares: 10, buyPrice: 150, buyDate: "2024-01-01"),
                makePayload(symbol: "MSFT", shares: 5, buyPrice: 300, buyDate: "2024-02-01"),
                makePayload(symbol: "NVDA", shares: 2.5, buyPrice: 800, buyDate: "2024-03-01"),
            ]

            let response = try await service.bulkCreate(
                payloads: payloads, userId: userId, on: app.db
            )

            #expect(response.created == 3)
            #expect(response.failed == 0)
            #expect(response.results.count == 3)

            let symbols = response.results.compactMap { $0.stock?.symbol }
            #expect(Set(symbols) == Set(["AAPL", "MSFT", "NVDA"]))

            let models = try await Stock.query(on: app.db)
                .filter(\.$userId == userId)
                .all()
            #expect(models.count == 3)
        }
    }

    @Test("bulkCreate() partial failure reports errors per item")
    func bulkCreatePartialFailure() async throws {
        try await withApp { app in
            let user = try await createUser(email: "service-bulk-partial@example.com", on: app.db)
            let userId = try user.requireID()

            let service = StockServiceImpl(repo: DatabaseStocksRepository(), req: makeRequest(app))
            let payloads = [
                makePayload(symbol: "AAPL", shares: 10, buyPrice: 150, buyDate: "2024-01-01"),
                makePayload(symbol: "BAD", shares: 1, buyPrice: 100, buyDate: "not-a-date"),
            ]

            let response = try await service.bulkCreate(
                payloads: payloads, userId: userId, on: app.db
            )

            #expect(response.created == 1)
            #expect(response.failed == 1)
            #expect(response.results.count == 2)
            #expect(response.results[0].stock?.symbol == "AAPL")
            #expect(response.results[0].error == nil)
            #expect(response.results[1].stock == nil)
            #expect(response.results[1].error != nil)
        }
    }

    @Test("bulkCreate() with empty array returns zero counts")
    func bulkCreateEmptyArray() async throws {
        try await withApp { app in
            let user = try await createUser(email: "service-bulk-empty@example.com", on: app.db)
            let userId = try user.requireID()

            let service = StockServiceImpl(repo: DatabaseStocksRepository(), req: makeRequest(app))
            let response = try await service.bulkCreate(payloads: [], userId: userId, on: app.db)

            #expect(response.created == 0)
            #expect(response.failed == 0)
            #expect(response.results.isEmpty)
        }
    }

    @Test("createValuation() requires an existing stock and round-trips through get/update")
    func valuationLifecycle() async throws {
        try await withApp { app in
            let user = try await createUser(email: "service-valuation@example.com", on: app.db)
            let userId = try user.requireID()

            let repo = DatabaseStocksRepository()
            _ = try await repo.create(
                payload: makePayload(symbol: "AAPL", buyDate: "2024-03-04"),
                userId: userId,
                on: app.db
            )

            let service = StockServiceImpl(repo: repo, req: makeRequest(app))
            let created = try await service.createValuation(
                symbol: "aapl",
                payload: makeValuationPayload(symbol: "AAPL", rationale: "  original thesis  "),
                userId: userId,
                on: app.db
            )
            #expect(created.symbol == "AAPL")
            #expect(created.rationale == "original thesis")

            let fetched = try await service.getValuation(symbol: "AAPL", userId: userId, on: app.db)
            #expect(fetched.baseCase.high == 22)

            let updated = try await service.updateValuation(
                symbol: "AAPL",
                payload: makeValuationPayload(symbol: "AAPL", baseHigh: 28, bullHigh: 35),
                userId: userId,
                on: app.db
            )
            #expect(updated.baseCase.high == 28)
            #expect(updated.bullCase.high == 35)
        }
    }

    @Test("createValuation() rejects mismatched route and body symbol")
    func valuationRejectsSymbolMismatch() async throws {
        try await withApp { app in
            let user = try await createUser(email: "service-valuation-mismatch@example.com", on: app.db)
            let userId = try user.requireID()

            let repo = DatabaseStocksRepository()
            _ = try await repo.create(
                payload: makePayload(symbol: "AAPL", buyDate: "2024-03-04"),
                userId: userId,
                on: app.db
            )

            let service = StockServiceImpl(repo: repo, req: makeRequest(app))

            do {
                _ = try await service.createValuation(
                    symbol: "AAPL",
                    payload: makeValuationPayload(symbol: "MSFT"),
                    userId: userId,
                    on: app.db
                )
                #expect(Bool(false), "Expected badRequest for symbol mismatch")
            } catch let abort as Abort {
                #expect(abort.status == .badRequest)
            }
        }
    }

    @Test("sell() auto-creates manual account and credits cash when account is missing")
    func sellAutoCreatesAccountAndCreditsCash() async throws {
        try await withApp { app in
            let user = try await createUser(email: "service-sell-autocreate@example.com", on: app.db)
            let userId = try user.requireID()

            let repo = DatabaseStocksRepository()
            let stock = try await repo.create(
                payload: makePayload(symbol: "AAPL", shares: 4, buyPrice: 100, buyDate: "2024-05-06"),
                userId: userId,
                on: app.db
            )

            let service = StockServiceImpl(repo: repo, req: makeRequest(app))
            let response = try await service.sell(
                id: stock.requireID(),
                payload: makeSellPayload(sharesToSell: 1.5, sellPrice: 160),
                userId: userId,
                on: app.db
            )

            #expect(response.shares == 2.5)

            let account = try await Account.query(on: app.db)
                .filter(\.$userId == userId)
                .first()
            #expect(account != nil)
            #expect(account?.broker == "manual")
            #expect(account?.baseCurrency == "USD")
            let accountId = try #require(account?.id)

            let cash = try await CashBalance.query(on: app.db)
                .filter(\.$accountId == accountId)
                .filter(\.$currency == "USD")
                .first()
            #expect(cash != nil)
            #expect(abs((cash?.balance ?? 0) - 240) < 0.001)
        }
    }

    @Test("sell() fully sold position removes stock and still credits cash")
    func sellFullyRemovesPosition() async throws {
        try await withApp { app in
            let user = try await createUser(email: "service-sell-full@example.com", on: app.db)
            let userId = try user.requireID()
            let account = try await createManualAccount(userId: userId, on: app.db)
            try await CashBalance(
                accountId: #require(account.id),
                currency: "USD",
                balance: 50,
                asOf: Date()
            ).save(on: app.db)

            let repo = DatabaseStocksRepository()
            let stock = try await repo.create(
                payload: makePayload(symbol: "MSFT", shares: 2, buyPrice: 200, buyDate: "2024-05-06"),
                userId: userId,
                on: app.db
            )

            let service = StockServiceImpl(repo: repo, req: makeRequest(app))
            let response = try await service.sell(
                id: stock.requireID(),
                payload: makeSellPayload(sharesToSell: 2, sellPrice: 220),
                userId: userId,
                on: app.db
            )
            let stockId = try stock.requireID()
            let accountId = try #require(account.id)

            #expect(response.shares == 0)

            let remainingStock = try await Stock.query(on: app.db)
                .filter(\.$userId == userId)
                .filter(\.$id == stockId)
                .first()
            #expect(remainingStock == nil)

            let updatedCash = try await CashBalance.query(on: app.db)
                .filter(\.$accountId == accountId)
                .filter(\.$currency == "USD")
                .first()
            #expect(abs((updatedCash?.balance ?? 0) - 490) < 0.001)
        }
    }

    @Test("sell() rejects invalid sell payload")
    func sellRejectsInvalidPayload() async throws {
        try await withApp { app in
            let user = try await createUser(email: "service-sell-invalid@example.com", on: app.db)
            let userId = try user.requireID()

            let repo = DatabaseStocksRepository()
            let stock = try await repo.create(
                payload: makePayload(symbol: "NVDA", shares: 3, buyPrice: 100, buyDate: "2024-05-06"),
                userId: userId,
                on: app.db
            )
            let service = StockServiceImpl(repo: repo, req: makeRequest(app))

            do {
                _ = try await service.sell(
                    id: stock.requireID(),
                    payload: makeSellPayload(sharesToSell: 1, sellPrice: 100, sellDate: "bad-date"),
                    userId: userId,
                    on: app.db
                )
                #expect(Bool(false), "Expected badRequest for invalid sellDate")
            } catch let abort as Abort {
                #expect(abort.status == .badRequest)
            }

            do {
                _ = try await service.sell(
                    id: stock.requireID(),
                    payload: makeSellPayload(sharesToSell: 1, sellPrice: 0, sellDate: "2026-04-10"),
                    userId: userId,
                    on: app.db
                )
                #expect(Bool(false), "Expected badRequest for invalid sellPrice")
            } catch let abort as Abort {
                #expect(abort.status == .badRequest)
            }
        }
    }
}
