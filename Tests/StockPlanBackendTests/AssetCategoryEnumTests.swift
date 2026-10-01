import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Asset category enum", .serialized)
struct AssetCategoryEnumTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withSharedAccess {
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

    private func registerUser(app: Application) async throws -> UUID {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        let request = StockPlanBackend.AuthRegisterRequest(
            username: "assetcat_\(suffix)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "assetcat+\(suffix)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var userId: UUID?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            userId = try res.content.decode(AuthResponse.self).userId
        })
        guard let userId else {
            throw Abort(.internalServerError, reason: "Auth register did not return a response")
        }
        return userId
    }

    @Test("every AssetCategory case can be stored on a holding")
    func everyCategoryPersists() async throws {
        try await withApp { app in
            let userId = try await registerUser(app: app)
            let listId = try await ensureDefaultPortfolioListId(userId: userId, on: app.db)

            for category in AssetCategory.allCases {
                let stock = Stock(
                    userId: userId,
                    portfolioListId: listId,
                    symbol: "SYM_\(category.rawValue)",
                    shares: 1,
                    buyPrice: 1,
                    buyDate: Date(timeIntervalSince1970: 1_704_067_200),
                    category: category
                )
                try await stock.save(on: app.db)
            }

            let stored = try await Stock.query(on: app.db)
                .filter(\.$userId == userId)
                .all()
                .map(\.category)
            #expect(Set(stored) == Set(AssetCategory.allCases))
        }
    }
}
