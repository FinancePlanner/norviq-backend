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
                #expect(reports[0].myActual == 20.0)
                #expect(reports[0].partnerActual == 0.0)
                #expect(reports[0].pillarActuals["fun"] == 20.0)
            })
        }
    }

    @Test("Monthly reports include split household totals")
    func monthlyReportSplitAggregation() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)

            var snapshotId = ""
            try await app.testing().test(.POST, "v1/budget/snapshots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(BudgetSnapshotRequest(monthStart: "2025-11-01", netSalary: 3000, targetShares: [:]))
            }, afterResponse: { res async throws in
                snapshotId = try res.content.decode(BudgetSnapshotResponse.self).id
            })

            try await app.testing().test(.POST, "v1/budget/items", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    BudgetPlanItemRequest(
                        snapshotId: snapshotId,
                        title: "Rent",
                        plannedAmount: 1000,
                        pillar: .fundamentals,
                        splitMode: .shared,
                        userSharePercent: 60
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Rent",
                        amount: 1000,
                        pillar: .fundamentals,
                        occurredOn: "2025-11-03",
                        splitMode: .shared,
                        userSharePercent: 60
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.GET, "v1/reports/expenses?granularity=month", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                let reports = try res.content.decode([BudgetMonthSummaryResponse].self)
                #expect(reports.count == 1)
                #expect(reports[0].planned == 1000)
                #expect(reports[0].actual == 1000)
                #expect(reports[0].myPlanned == 600)
                #expect(reports[0].partnerPlanned == 400)
                #expect(reports[0].myActual == 600)
                #expect(reports[0].partnerActual == 400)
                #expect(reports[0].myPillarActuals["fundamentals"] == 600)
                #expect(reports[0].partnerPillarPlans["fundamentals"] == 400)
            })
        }
    }

    @Test("Household partner profile can be saved")
    func householdPartnerProfile() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)

            try await app.testing().test(.PUT, "v1/expenses/partner", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(HouseholdPartnerProfileRequest(displayName: "Ana"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(HouseholdPartnerProfileResponse.self)
                #expect(response.displayName == "Ana")
            })

            try await app.testing().test(.GET, "v1/expenses/partner", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(HouseholdPartnerProfileResponse.self)
                #expect(response.displayName == "Ana")
            })
        }
    }

    @Test("Creating expense rejects invalid linked plan item id format")
    func expenseRejectsInvalidLinkedPlanItemIdFormat() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)

            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Groceries",
                        amount: 45,
                        pillar: .fundamentals,
                        occurredOn: "2025-11-03",
                        linkedPlanItemId: "not-a-uuid"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Reports overview aggregates portfolio and cash flow data")
    func reportsOverviewAggregation() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)

            var snapshotId = ""
            try await app.testing().test(.POST, "v1/budget/snapshots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                let reqBody = BudgetSnapshotRequest(
                    monthStart: "2025-11-01",
                    netSalary: 3000,
                    targetShares: ["fundamentals": 0.5, "futureYou": 0.2, "fun": 0.3]
                )
                try req.content.encode(reqBody)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                snapshotId = try res.content.decode(BudgetSnapshotResponse.self).id
            })

            try await app.testing().test(.POST, "v1/budget/items", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    BudgetPlanItemRequest(
                        snapshotId: snapshotId,
                        title: "Groceries",
                        plannedAmount: 900,
                        pillar: .fundamentals
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Groceries",
                        amount: 650,
                        pillar: .fundamentals,
                        occurredOn: "2025-11-03"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Concert",
                        amount: 120,
                        pillar: .fun,
                        occurredOn: "2025-11-08"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.GET, "v1/reports/overview", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let overview = try res.content.decode(ReportsOverviewResponse.self)
                #expect(overview.monthlySummaries.count == 1)
                #expect(overview.yearlySummaries.count == 1)
                #expect(overview.latestMonthSummary?.salary == 3000)
                #expect(overview.latestMonthSummary?.actual == 770)
                #expect(overview.cashFlow.count == 1)
                #expect(overview.cashFlow[0].income == 3000)
                #expect(overview.cashFlow[0].expenses == 770)
                #expect(overview.cashFlow[0].net == 2230)
                #expect(overview.latestPillarSummaries.count == 3)
                #expect(overview.latestPillarSummaries.first(where: { $0.pillar == .fundamentals })?.plannedAmount == 900)
                #expect(overview.latestPillarSummaries.first(where: { $0.pillar == .fundamentals })?.actualAmount == 650)
                #expect(overview.latestPillarSummaries.first(where: { $0.pillar == .fun })?.unplannedActualAmount == 120)
            })
        }
    }

    @Test("Creating plan items and expenses respects percentage allocation details")
    func testPercentageAllocationDetails() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)
            var snapshotId = ""
            try await app.testing().test(.POST, "v1/budget/snapshots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(BudgetSnapshotRequest(monthStart: "2025-12-01", netSalary: 5000, targetShares: [:]))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                snapshotId = try res.content.decode(BudgetSnapshotResponse.self).id
            })

            // Add pillar (Budget Plan Item)
            var planItemId = ""
            try await app.testing().test(.POST, "v1/budget/items", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    BudgetPlanItemRequest(
                        snapshotId: snapshotId,
                        title: "Mortgage",
                        plannedAmount: 2000,
                        pillar: .fundamentals,
                        splitMode: .shared,
                        userSharePercent: 35
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let item = try res.content.decode(BudgetPlanItemResponse.self)
                #expect(item.splitMode == .shared)
                #expect(item.userSharePercent == 35)
                planItemId = item.id
            })

            // Add expense related to pillar
            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Mortgage Payment",
                        amount: 2000,
                        pillar: .fundamentals,
                        occurredOn: "2025-12-05",
                        linkedPlanItemId: planItemId,
                        splitMode: .shared,
                        userSharePercent: 35
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let dict = try res.content.decode(ExpenseResponse.self)
                #expect(dict.splitMode == .shared)
                #expect(dict.userSharePercent == 35)
                #expect(dict.linkedPlanItemId == planItemId)
            })
        }
    }

    @Test("Report suggestions endpoint returns deterministic rule-based items")
    func reportSuggestionsDeterministic() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)

            var snapshotId = ""
            try await app.testing().test(.POST, "v1/budget/snapshots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(BudgetSnapshotRequest(monthStart: "2026-03-01", netSalary: 3000, targetShares: [:]))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                snapshotId = try res.content.decode(BudgetSnapshotResponse.self).id
            })

            try await app.testing().test(.POST, "v1/budget/items", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    BudgetPlanItemRequest(
                        snapshotId: snapshotId,
                        title: "Core Living",
                        plannedAmount: 1000,
                        pillar: .fundamentals
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Core Living",
                        amount: 1400,
                        pillar: .fundamentals,
                        occurredOn: "2026-03-05"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Unplanned Weekend",
                        amount: 350,
                        pillar: .fun,
                        occurredOn: "2026-03-12"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.GET, "v1/reports/suggestions", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(ReportSuggestionsResponse.self)
                #expect(payload.suggestions.isEmpty == false)
                #expect(payload.suggestions.contains(where: { $0.category == .overspend }))
                #expect(payload.suggestions.contains(where: { $0.category == .unplannedSpend }))
            })
        }
    }

    @Test("Dismissed suggestions are hidden from subsequent suggestion fetches")
    func dismissSuggestionPersists() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)

            var snapshotId = ""
            try await app.testing().test(.POST, "v1/budget/snapshots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(BudgetSnapshotRequest(monthStart: "2026-04-01", netSalary: 2800, targetShares: [:]))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                snapshotId = try res.content.decode(BudgetSnapshotResponse.self).id
            })

            try await app.testing().test(.POST, "v1/budget/items", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    BudgetPlanItemRequest(
                        snapshotId: snapshotId,
                        title: "Essentials",
                        plannedAmount: 900,
                        pillar: .fundamentals
                    )
                )
            }, afterResponse: { _ async throws in })

            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Essentials",
                        amount: 1300,
                        pillar: .fundamentals,
                        occurredOn: "2026-04-06"
                    )
                )
            }, afterResponse: { _ async throws in })

            var suggestionId = ""
            try await app.testing().test(.GET, "v1/reports/suggestions", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                let payload = try res.content.decode(ReportSuggestionsResponse.self)
                suggestionId = try #require(payload.suggestions.first?.id)
            })

            try await app.testing().test(
                .POST,
                "v1/reports/suggestions/\(suggestionId)/dismiss",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let success = try res.content.decode(APISuccess.self)
                    #expect(success.success == true)
                }
            )

            try await app.testing().test(.GET, "v1/reports/suggestions", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                let payload = try res.content.decode(ReportSuggestionsResponse.self)
                #expect(payload.suggestions.contains(where: { $0.id == suggestionId }) == false)
            })
        }
    }
}
