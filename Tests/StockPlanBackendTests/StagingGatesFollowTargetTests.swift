import Fluent
import FluentSQL
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// I2: a portfolio a broker sync writes into is never a follow target.
extension StagingGatesTests {
    @Test("a portfolio bound to a broker connection is not a follow target")
    func brokerBoundListIsNotAFollowTarget() async throws {
        try await withApp { app in
            let (_, userId) = try await registerTestUser(app: app)
            let pilot = try await seededBook(on: app.db)
            let pro = EntitlementSnapshot(userId: userId, level: "pro")
            let bound = PortfolioList(userId: userId, name: "Bound sandbox", mode: "hypothetical")
            try await bound.create(on: app.db)
            try await BrokerConnection(userId: userId, provider: "ibkr", status: "connected", portfolioListId: bound.requireID()).create(on: app.db)
            do {
                _ = try await followService.create(
                    PilotFollowCreateRequest(pilotSlug: pilot.slug, targetKind: .portfolio, portfolioListId: bound.requireID().uuidString, watchlistListId: nil, startingCapital: 1000),
                    userId: userId, entitlement: pro, now: Date(), on: app.db
                )
                Issue.record("followed into a broker-bound portfolio")
            } catch let error as any AbortError {
                #expect(error.status == .unprocessableEntity, "\(error.reason)")
            }
            #expect(try await PilotFollow.query(on: app.db).filter(\.$userId == userId).count() == 0)

            // The same kind of list without a connection is still a valid target.
            let free = PortfolioList(userId: userId, name: "Free sandbox", mode: "hypothetical")
            try await free.create(on: app.db)
            let follow = try await followService.create(
                PilotFollowCreateRequest(pilotSlug: pilot.slug, targetKind: .portfolio, portfolioListId: free.requireID().uuidString, watchlistListId: nil, startingCapital: 1000),
                userId: userId, entitlement: pro, now: Date(), on: app.db
            )
            #expect(follow.portfolioListId == free.id)
        }
    }
}
