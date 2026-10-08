import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Vapor
import VaporTesting

enum MarketBriefFixtures {
    static func response(
        date: String = "2026-10-08",
        slot: MarketBriefSlot = .morning,
        language: String = "en",
        degraded: Bool = false
    ) -> MarketBriefResponse {
        MarketBriefResponse(
            enabled: true,
            tradingDate: date,
            slot: slot,
            language: language,
            greeting: language == "en" ? "Good morning," : "Bom dia,",
            groups: [],
            items: [MarketBriefItem(kind: slot == .morning ? .highlight : .story, text: "Line for \(language).", tickers: [], sourceUrl: nil)],
            generatedAt: "2026-10-08T07:15:00Z",
            degraded: degraded
        )
    }

    /// Configured, migrated app inside the shared DB lock, the same shape as
    /// `MarketOwnershipRouteTests.withApp`.
    static func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withSharedAccess {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
                try await app.asyncShutdown()
            } catch {
                try? await app.autoRevert()
                try? await app.asyncShutdown()
                throw error
            }
        }
    }
}
