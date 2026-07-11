import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Expense CSV Import/Export Tests", .serialized)
struct ExpenseCsvTests {
    private func withApp(_ test: @escaping (Application) async throws -> Void) async throws {
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

    private func registerUser(app: Application) async throws -> String {
        let id = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "csv_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "csv_\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            token = try res.content.decode(AuthResponse.self).token
        })
        return token
    }

    private let sampleCSV = """
    title,amount,pillar,occurred_on
    Coffee,4.50,fundamentals,2026-07-05
    Lunch,12.00,fun,2026-07-06
    """

    @Test("Dry-run import writes nothing but reports rows")
    func dryRunImportsNothing() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)
            try await app.testing().test(.POST, "v1/expenses/import?dry_run=true", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.contentType = .init(type: "text", subType: "csv")
                req.body = ByteBuffer(string: sampleCSV)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let result = try res.content.decode(ExpenseCsvService.ImportResult.self)
                #expect(result.dryRun == true)
                #expect(result.imported == 2)
                #expect(result.total == 2)
            })
            // Nothing persisted.
            try await app.testing().test(.GET, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                let items = try res.content.decode([ExpenseResponse].self)
                #expect(items.isEmpty)
            })
        }
    }

    @Test("Real import persists rows and re-import dedups")
    func realImportAndDedup() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)
            try await app.testing().test(.POST, "v1/expenses/import?dry_run=false", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.contentType = .init(type: "text", subType: "csv")
                req.body = ByteBuffer(string: sampleCSV)
            }, afterResponse: { res async throws in
                let result = try res.content.decode(ExpenseCsvService.ImportResult.self)
                #expect(result.imported == 2)
            })
            // Re-importing the same rows dedups.
            try await app.testing().test(.POST, "v1/expenses/import?dry_run=false", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.contentType = .init(type: "text", subType: "csv")
                req.body = ByteBuffer(string: sampleCSV)
            }, afterResponse: { res async throws in
                let result = try res.content.decode(ExpenseCsvService.ImportResult.self)
                #expect(result.imported == 0)
                #expect(result.skipped == 2)
            })
        }
    }

    @Test("Export returns CSV with BOM and rows")
    func exportCSV() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)
            try await app.testing().test(.POST, "v1/expenses/import?dry_run=false", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.contentType = .init(type: "text", subType: "csv")
                req.body = ByteBuffer(string: sampleCSV)
            }, afterResponse: { _ async in })

            try await app.testing().test(.GET, "v1/expenses/export.csv", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                let body = res.body.string
                #expect(body.hasPrefix("\u{FEFF}"))
                #expect(body.contains("Coffee"))
                #expect(body.contains("Lunch"))
            })
        }
    }

    @Test("Import rejects a malformed row but imports the rest")
    func partialFailure() async throws {
        try await withApp { app in
            let token = try await registerUser(app: app)
            let csv = """
            title,amount,pillar,occurred_on
            Good,5,fundamentals,2026-07-05
            Bad,notanumber,fundamentals,2026-07-06
            """
            try await app.testing().test(.POST, "v1/expenses/import?dry_run=true", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.contentType = .init(type: "text", subType: "csv")
                req.body = ByteBuffer(string: csv)
            }, afterResponse: { res async throws in
                let result = try res.content.decode(ExpenseCsvService.ImportResult.self)
                #expect(result.imported == 1)
                #expect(result.failed == 1)
            })
        }
    }
}
