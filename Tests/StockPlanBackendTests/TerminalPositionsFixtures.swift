import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Vapor
import VaporTesting

enum TerminalFixtures {
    /// Configured, migrated app inside the shared DB lock.
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

    static func registerUser(app: Application) async throws -> (token: String, userId: UUID) {
        let id = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "tps_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "tps_\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            token = try res.content.decode(AuthResponse.self).token
        })
        let userId = try await app.jwt.keys.verify(token, as: SessionToken.self).userId
        return (token, userId)
    }

    static func amzn() -> TerminalPositionCreateRequest {
        TerminalPositionCreateRequest(
            ticker: "amzn", sharesOutstanding: 10_600_000_000, terminalShareCount: 11_000_000_000,
            terminalMarketCap: 10_000_000_000_000, valueWanted: 1_000_000, sharesOwned: 750
        )
    }

    static func vg() -> TerminalPositionCreateRequest {
        TerminalPositionCreateRequest(
            ticker: "VG", terminalShareCount: 200_000_000, terminalMarketCap: 12_500_000_000, valueWanted: 500_000
        )
    }
}
