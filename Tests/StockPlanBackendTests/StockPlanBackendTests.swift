@testable import StockPlanBackend
import VaporTesting
import Testing
import Fluent
import NIOCore

@Suite("App Tests with DB", .serialized)
struct StockPlanBackendTests {
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

    private func registerTestUser(app: Application) async throws -> (token: String, userId: UUID) {
        let register = AuthRegisterRequest(email: "test@example.com", password: "Password123")
        var response: AuthResponse?

        try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })

        guard let response else {
            throw Abort(.internalServerError, reason: "Auth register did not return a response")
        }
        return (response.token, response.userId)
    }
    
    @Test("Test Hello World Route")
    func helloWorld() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "hello", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "Hello, world!")
            })
        }
    }
    
    @Test("Getting all the Todos")
    func getAllTodos() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let sampleTodos = [
                Todo(userId: userId, title: "sample1"),
                Todo(userId: userId, title: "sample2"),
            ]
            try await sampleTodos.create(on: app.db)
            
            try await app.testing().test(.GET, "todos", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try
                    res.content.decode([TodoDTO].self).sorted(by: { $0.title < $1.title }) ==
                    sampleTodos.map { $0.toDTO() }.sorted(by: { $0.title < $1.title })
                )
            })
        }
    }
    
    @Test("Creating a Todo")
    func createTodo() async throws {
        let newDTO = TodoDTO(id: nil, title: "test")
        
        try await withApp { app in
            let (token, _) = try await registerTestUser(app: app)

            try await app.testing().test(.POST, "todos", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(newDTO)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let models = try await Todo.query(on: app.db).all()
                #expect(models.map({ $0.toDTO().title }) == [newDTO.title])
            })
        }
    }
    
    @Test("Deleting a Todo")
    func deleteTodo() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let testTodos = [Todo(userId: userId, title: "test1"), Todo(userId: userId, title: "test2")]
            try await testTodos.create(on: app.db)
            
            try await app.testing().test(.DELETE, "todos/\(testTodos[0].requireID())", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .noContent)
                let model = try await Todo.find(testTodos[0].id, on: app.db)
                #expect(model == nil)
            })
        }
    }

    @Test("Importing stocks from CSV (commit)")
    func importStocksFromCsvCommit() async throws {
        try await withApp { app in
            let (token, _) = try await registerTestUser(app: app)

            let csv = """
            symbol,shares,buy_price,buy_date,notes
            AAPL,12,145.30,2026-01-10,Long-term core
            """

            var importResponse: CsvImportCommitResponse?
            try await app.testing().test(.POST, "brokers/import/csv/commit?provider=ibkr", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.replaceOrAdd(name: .contentType, value: "text/csv")
                req.body = ByteBufferAllocator().buffer(string: csv)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                importResponse = try res.content.decode(CsvImportCommitResponse.self)
            })

            #expect(importResponse?.errors.isEmpty == true)
            #expect(importResponse?.inserted.count == 1)
            #expect(importResponse?.provider == "ibkr")

            try await app.testing().test(.GET, "brokers", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let brokers = try res.content.decode([BrokerConnectionResponse].self)
                let hasIbkrCsv = brokers.contains { broker in
                    broker.provider == "ibkr" && broker.status == "csv"
                }
                #expect(hasIbkrCsv)
            })

            try await app.testing().test(.GET, "stocks", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let stocks = try res.content.decode([StockResponse].self)
                let hasAAPL = stocks.contains { stock in
                    stock.symbol == "AAPL" && stock.shares == 12
                }
                #expect(hasAAPL)
            })
        }
    }
}

extension TodoDTO: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title
    }
}
