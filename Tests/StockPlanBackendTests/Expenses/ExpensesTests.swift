@testable import StockPlanBackend
import VaporTesting
import Testing
import Fluent
import Foundation
import StockPlanShared
import Vapor

@Suite("Expenses & Reports Service Tests", .serialized)
struct ExpensesTests {
    private func withExpensesApp(_ test: @escaping (Application) async throws -> Void) async throws {
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

    private func registerTestUser(app: Application) async throws -> String {
        let identifier = UUID().uuidString.prefix(8).lowercased()
        let register = AuthRegisterRequest(
            username: "exp_user_\(identifier)",
            password: "Password123",
            email: "exp_\(identifier)@example.com",
            firstName: "Exp",
            lastName: "Tester",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token: String = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            let response = try res.content.decode(AuthResponse.self)
            token = response.token
        })
        return token
    }

    @Test("Monthly report aggregation")
    func monthlyReportAggregation() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)
            
            // 1. Create a snapshot
            var snapshotId: String = ""
            try await app.testing().test(.POST, "v1/budget/snapshots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                let reqBody = BudgetSnapshotRequest(monthStart: "2025-11-01", netSalary: 3000, targetShares: [:])
                try req.content.encode(reqBody)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let snap = try res.content.decode(BudgetSnapshotResponse.self)
                snapshotId = snap.id
            })
            
            // 2. Add some expenses
            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                let expense = ExpenseRequest(title: "Lunch", amount: 20, pillar: .fun, occurredOn: "2025-11-05")
                try req.content.encode(expense)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })
            
            // 3. Fetch report
            try await app.testing().test(.GET, "v1/reports/expenses?granularity=month&from=2025-11-01&to=2025-11-30", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let reports = try res.content.decode([BudgetMonthSummaryResponse].self)
                #expect(reports.count == 1)
                #expect(reports[0].actual == 20.0)
                #expect(reports[0].pillarActuals["fun"] == 20.0)
            })
        }
    }
}
