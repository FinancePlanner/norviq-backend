import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("PilotController", .serialized)
struct PilotControllerTests {
    func withApp(_ test: (Application) async throws -> Void) async throws {
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

    func registerTestUser(app: Application) async throws -> (token: String, userId: UUID) {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        let request = StockPlanBackend.AuthRegisterRequest(
            username: "pilot_\(suffix)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "pilot+\(suffix)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var response: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })
        guard let response else {
            throw Abort(.internalServerError, reason: "Auth register did not return a response")
        }
        return (response.token, response.userId)
    }

    @Test("flag off: 404", .databaseLocked)
    func flagOff() async throws {
        unsetenv("PILOTS_ENABLED")
        try await withApp { app in
            let (token, _) = try await registerTestUser(app: app)
            try await app.testing().test(.GET, "v1/pilots", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }) { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("flag on: list pilots, follow into a watchlist, read events, pause, delete", .databaseLocked)
    func lifecycle() async throws {
        setenv("PILOTS_ENABLED", "true", 1)
        defer { unsetenv("PILOTS_ENABLED") }
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let pilot = try #require(try await Pilot.query(on: app.db).filter(\.$slug == "nancy-pelosi").first())
            try await PilotBookVersion(pilotId: pilot.requireID(), version: 1, computedAt: Date(), weights: ["NVDA": 1.0], skippedPuts: 0).create(on: app.db)

            try await app.testing().test(.GET, "v1/pilots", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }) { res in
                #expect(res.status == .ok)
                let pilots = try res.content.decode([PilotSummary].self)
                #expect(pilots.contains { $0.slug == "nancy-pelosi" && $0.holdingsCount == 1 })
            }
            try await app.testing().test(.GET, "v1/pilots/nancy-pelosi", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }) { res in
                let detail = try res.content.decode(PilotDetail.self)
                #expect(detail.weights == [PilotWeight(symbol: "NVDA", weight: 1.0)])
                #expect(detail.lagNote.contains("45 days"))
            }

            var created: PilotFollowResponse?
            try await app.testing().test(.POST, "v1/pilot-follows", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(PilotFollowCreateRequest(pilotSlug: "nancy-pelosi", targetKind: .watchlist, portfolioListId: nil, watchlistListId: nil, startingCapital: nil))
            }) { res in
                #expect(res.status == .created)
                created = try res.content.decode(PilotFollowResponse.self)
            }
            let follow = try #require(created)
            #expect(follow.appliedVersion == 1)

            try await app.testing().test(.GET, "v1/pilot-follows/\(follow.id)/events", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }) { res in
                let events = try res.content.decode([PilotFollowEventResponse].self)
                #expect(events.map(\.kind) == ["watch_added"])
            }
            try await app.testing().test(.PATCH, "v1/pilot-follows/\(follow.id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(PilotFollowUpdateRequest(status: .paused))
            }) { res in
                let updated = try res.content.decode(PilotFollowResponse.self)
                #expect(updated.status == .paused)
            }
            try await app.testing().test(.DELETE, "v1/pilot-follows/\(follow.id)", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }) { res in
                #expect(res.status == .noContent)
            }
            // Deleting the follow keeps what it wrote.
            #expect(try await WatchlistItem.query(on: app.db).filter(\.$userId == userId).count() == 1)
        }
    }

    @Test("another user's follow is a 404", .databaseLocked)
    func ownership() async throws {
        setenv("PILOTS_ENABLED", "true", 1)
        defer { unsetenv("PILOTS_ENABLED") }
        try await withApp { app in
            let (_, ownerId) = try await registerTestUser(app: app)
            let (intruder, _) = try await registerTestUser(app: app)
            let pilot = try #require(try await Pilot.query(on: app.db).filter(\.$slug == "nancy-pelosi").first())
            let list = WatchlistList(userId: ownerId, name: "Owner feed")
            try await list.create(on: app.db)
            let follow = try PilotFollow(userId: ownerId, pilotId: pilot.requireID(), targetKind: .watchlist, watchlistListId: list.requireID())
            try await follow.create(on: app.db)
            try await app.testing().test(.GET, "v1/pilot-follows/\(follow.requireID())", beforeRequest: { $0.headers.bearerAuthorization = .init(token: intruder) }) { res in
                #expect(res.status == .notFound)
            }
        }
    }
}
