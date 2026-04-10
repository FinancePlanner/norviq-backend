@testable import StockPlanBackend
import VaporTesting
import Testing
import Fluent
import Foundation
import StockPlanShared

@Suite("UserActivity Tests", .serialized)
struct UserActivityTests {
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

    private func createTestUser(app: Application, email: String = "test@example.com") async throws -> (User, String) {
        let uniqueSuffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
        let registerReq = AuthRegisterRequest(
            username: "user_\(uniqueSuffix)",
            password: "Password123",
            email: email,
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(registerReq)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            let response = try res.content.decode(AuthResponse.self)
            token = response.token
        })
        
        let user = try await User.query(on: app.db).filter(\.$email == email).first()
        guard let user = user else {
            throw Abort(.internalServerError, reason: "User not created")
        }
        
        return (user, token)
    }

    // MARK: - Get Activities Tests

    @Test("Get activities returns empty array for new user")
    func getActivitiesEmpty() async throws {
        try await withApp { app in
            let (_, token) = try await createTestUser(app: app)
            
            try await app.testing().test(.GET, "v1/activities", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let activities = try res.content.decode([UserActivityResponse].self)
                #expect(activities.isEmpty)
            })
        }
    }

    @Test("Get activities returns user activities")
    func getActivitiesWithData() async throws {
        try await withApp { app in
            let (user, token) = try await createTestUser(app: app)
            let userId = try user.requireID()
            
            // Create test activities
            let activity1 = UserActivity(
                userId: userId,
                type: .stockAdded,
                title: "Stock Added",
                subtitle: "AAPL - Apple Inc.",
                amount: 5000.00,
                isGrowth: true,
                symbol: "chart.line.uptrend.xyaxis"
            )
            try await activity1.save(on: app.db)
            
            let activity2 = UserActivity(
                userId: userId,
                type: .expenseRecorded,
                title: "Expense Added",
                subtitle: "Groceries",
                amount: 150.00,
                isGrowth: false,
                symbol: "house.fill"
            )
            try await activity2.save(on: app.db)
            
            try await app.testing().test(.GET, "v1/activities", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let activities = try res.content.decode([UserActivityResponse].self)
                #expect(activities.count == 2)
                
                // Should be sorted by createdAt descending (newest first)
                #expect(activities[0].type == .expenseRecorded)
                #expect(activities[0].title == "Expense Added")
                #expect(activities[0].subtitle == "Groceries")
                #expect(activities[0].amount == 150.00)
                #expect(activities[0].isGrowth == false)
                #expect(activities[0].symbol == "house.fill")
                
                #expect(activities[1].type == .stockAdded)
                #expect(activities[1].title == "Stock Added")
                #expect(activities[1].subtitle == "AAPL - Apple Inc.")
                #expect(activities[1].amount == 5000.00)
                #expect(activities[1].isGrowth == true)
                #expect(activities[1].symbol == "chart.line.uptrend.xyaxis")
            })
        }
    }

    @Test("Get activities respects limit parameter")
    func getActivitiesWithLimit() async throws {
        try await withApp { app in
            let (user, token) = try await createTestUser(app: app)
            let userId = try user.requireID()
            
            // Create 5 test activities
            for i in 1...5 {
                let activity = UserActivity(
                    userId: userId,
                    type: .stockAdded,
                    title: "Stock Added \(i)",
                    subtitle: "TEST\(i)",
                    amount: Double(i * 1000),
                    isGrowth: true,
                    symbol: "chart.line.uptrend.xyaxis"
                )
                try await activity.save(on: app.db)
            }
            
            try await app.testing().test(.GET, "v1/activities?limit=3", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let activities = try res.content.decode([UserActivityResponse].self)
                #expect(activities.count == 3)
            })
        }
    }

    @Test("Get activities requires authentication")
    func getActivitiesUnauthorized() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/activities", afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Get activities only returns current user's activities")
    func getActivitiesUserIsolation() async throws {
        try await withApp { app in
            let (user1, token1) = try await createTestUser(app: app, email: "user1@example.com")
            let (user2, _) = try await createTestUser(app: app, email: "user2@example.com")
            
            let userId1 = try user1.requireID()
            let userId2 = try user2.requireID()
            
            // Create activity for user1
            let activity1 = UserActivity(
                userId: userId1,
                type: .stockAdded,
                title: "User 1 Stock",
                subtitle: "AAPL",
                amount: 1000.00,
                isGrowth: true,
                symbol: "chart.line.uptrend.xyaxis"
            )
            try await activity1.save(on: app.db)
            
            // Create activity for user2
            let activity2 = UserActivity(
                userId: userId2,
                type: .stockAdded,
                title: "User 2 Stock",
                subtitle: "MSFT",
                amount: 2000.00,
                isGrowth: true,
                symbol: "chart.line.uptrend.xyaxis"
            )
            try await activity2.save(on: app.db)
            
            // User1 should only see their own activity
            try await app.testing().test(.GET, "v1/activities", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token1)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let activities = try res.content.decode([UserActivityResponse].self)
                #expect(activities.count == 1)
                #expect(activities[0].subtitle == "AAPL")
            })
        }
    }

    // MARK: - Activity Recording Integration Tests

    @Test("Stock creation records activity")
    func stockCreationRecordsActivity() async throws {
        try await withApp { app in
            let (_, token) = try await createTestUser(app: app)
            
            let stockReq = StockRequest(
                symbol: "AAPL",
                shares: 10,
                buyPrice: 150.00,
                buyDate: "2024-01-01",
                notes: "Test stock",
                category: .stock
            )
            
            try await app.testing().test(.POST, "v1/stocks", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(stockReq)
            }, afterResponse: { res async in
                #expect(res.status == .created)
            })
            
            // Check that activity was recorded
            try await app.testing().test(.GET, "v1/activities", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let activities = try res.content.decode([UserActivityResponse].self)
                #expect(activities.count == 1)
                #expect(activities[0].type == .stockAdded)
                #expect(activities[0].title == "AAPL")
                #expect(activities[0].subtitle == "Added to portfolio")
            })
        }
    }

    @Test("Expense creation records activity")
    func expenseCreationRecordsActivity() async throws {
        try await withApp { app in
            let (user, token) = try await createTestUser(app: app)
            let userId = try user.requireID()
            
            // Create a budget snapshot first
            let snapshot = BudgetSnapshot(
                userID: userId,
                monthStart: Date(),
                netSalary: 5000.00,
                targetShares: ["fundamentals": 0.5, "futureYou": 0.3, "fun": 0.2]
            )
            try await snapshot.save(on: app.db)
            
            let expenseReq = ExpenseRequest(
                title: "Groceries",
                amount: 150.00,
                pillar: .fundamentals,
                occurredOn: "2026-04-06",
                linkedPlanItemId: nil
            )
            
            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(expenseReq)
            }, afterResponse: { res async in
                #expect(res.status == .created)
            })
            
            // Check that activity was recorded
            try await app.testing().test(.GET, "v1/activities", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let activities = try res.content.decode([UserActivityResponse].self)
                #expect(activities.count == 1)
                #expect(activities[0].type == .expenseRecorded)
                #expect(activities[0].subtitle == "Groceries")
                #expect(activities[0].amount == 150.00)
            })
        }
    }
}
