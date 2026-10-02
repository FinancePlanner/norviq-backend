import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// G5: a third-party token needs write access to what the follow writes into.
/// Lives in the PilotController suite: it flips PILOTS_ENABLED.
extension PilotControllerTests {
    private func mintPAT(_ app: Application, userId: UUID, scopes: [APIScope]) async throws -> String {
        let raw = OpaqueToken.generate(prefix: OpaqueToken.patPrefix)
        try await PersonalAccessToken(
            userId: userId,
            name: "pilot-scope-test",
            tokenHash: OpaqueToken.sha256Hex(raw),
            scopes: scopes.map(\.rawValue),
            expiresAt: Date().addingTimeInterval(3600)
        ).save(on: app.db)
        return raw
    }

    private func postFollow(_ app: Application, token: String, kind: PilotFollowTargetKind, _ check: @escaping (TestingHTTPResponse) async throws -> Void) async throws {
        try await app.testing().test(.POST, "v1/pilot-follows", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(PilotFollowCreateRequest(
                pilotSlug: "nancy-pelosi",
                targetKind: kind,
                portfolioListId: nil,
                watchlistListId: nil,
                startingCapital: kind == .portfolio ? 10000 : nil
            ))
        }) { res async throws in try await check(res) }
    }

    @Test("POST /v1/pilot-follows needs holdings:write or watchlist:write on top of portfolio:write for tokens", .databaseLocked)
    func followCreationScopes() async throws {
        setenv("PILOTS_ENABLED", "true", 1)
        defer { unsetenv("PILOTS_ENABLED") }
        try await withApp { app in
            let (session, userId) = try await registerTestUser(app: app)
            try await Entitlement(userId: userId, level: "pro").save(on: app.db)
            let pilot = try #require(try await Pilot.query(on: app.db).filter(\.$slug == "nancy-pelosi").first())
            try await PilotBookVersion(pilotId: pilot.requireID(), version: 1, computedAt: Date(), weights: ["NVDA": 1.0], skippedPuts: 0).create(on: app.db)

            let portfolioOnly = try await mintPAT(app, userId: userId, scopes: [.portfolioRead, .portfolioWrite])
            for kind in [PilotFollowTargetKind.portfolio, .watchlist] {
                try await postFollow(app, token: portfolioOnly, kind: kind) { res in
                    #expect(res.status == .forbidden, "\(kind): \(res.status) \(res.body.string)")
                    let needed = kind == .portfolio ? "holdings:write" : "watchlist:write"
                    #expect(res.body.string.contains("insufficient_scope: '\(needed)' required"), "\(res.body.string)")
                }
            }
            #expect(try await PilotFollow.query(on: app.db).filter(\.$userId == userId).count() == 0)
            #expect(try await PortfolioList.query(on: app.db).filter(\.$userId == userId).count() == 0)
            #expect(try await WatchlistList.query(on: app.db).filter(\.$userId == userId).count() == 0)

            // The wrong extra scope does not stand in for the right one.
            let watchOnly = try await mintPAT(app, userId: userId, scopes: [.portfolioWrite, .watchlistWrite])
            try await postFollow(app, token: watchOnly, kind: .portfolio) { res in
                #expect(res.status == .forbidden, "\(res.status) \(res.body.string)")
            }
            try await postFollow(app, token: watchOnly, kind: .watchlist) { res in
                #expect(res.status == .created, "\(res.status) \(res.body.string)")
            }
            let holdings = try await mintPAT(app, userId: userId, scopes: [.portfolioWrite, .holdingsWrite])
            try await postFollow(app, token: holdings, kind: .portfolio) { res in
                #expect(res.status == .created, "\(res.status) \(res.body.string)")
            }

            // First-party sessions carry every scope.
            for kind in [PilotFollowTargetKind.portfolio, .watchlist] {
                try await postFollow(app, token: session, kind: kind) { res in
                    #expect(res.status == .created, "session \(kind): \(res.status) \(res.body.string)")
                }
            }
            #expect(try await PilotFollow.query(on: app.db).filter(\.$userId == userId).count() == 4)
        }
    }
}
