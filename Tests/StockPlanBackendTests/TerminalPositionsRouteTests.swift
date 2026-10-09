import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Terminal positions routes", .serialized)
struct TerminalPositionsRouteTests {
    private func mintPAT(app: Application, userId: UUID, scopes: [APIScope]) async throws -> String {
        let raw = OpaqueToken.generate(prefix: OpaqueToken.patPrefix)
        let pat = PersonalAccessToken(
            userId: userId, name: "test", tokenHash: OpaqueToken.sha256Hex(raw),
            scopes: scopes.map(\.rawValue), expiresAt: Date().addingTimeInterval(3600)
        )
        try await pat.save(on: app.db)
        return raw
    }

    private func send(
        _ app: Application, _ method: HTTPMethod, _ path: String, token: String?,
        body: (some Encodable & Sendable)? = String?.none,
        _ check: @escaping (TestingHTTPResponse) async throws -> Void
    ) async throws {
        try await app.testing().test(method, path, beforeRequest: { req in
            if let token {
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }
            if let body {
                try req.content.encode(body, as: .json)
            }
        }, afterResponse: check)
    }

    @Test("No token is 401; a PAT without planning scopes is 403")
    func authMatrix() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let wrong = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesRead])
            try await send(app, .GET, "v1/terminal-positions", token: nil) { res in
                #expect(res.status == .unauthorized)
            }
            try await send(app, .GET, "v1/terminal-positions", token: wrong) { res in
                #expect(res.status == .forbidden)
            }
            try await send(app, .GET, "v1/autobuys", token: wrong) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("Create, list with ticker filter, patch, duplicate, reorder, summary, delete")
    func lifecycle() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            var createdId = ""
            try await send(app, .POST, "v1/terminal-positions", token: user.token, body: TerminalFixtures.amzn()) { res in
                #expect(res.status == .created)
                let body = try res.content.decode(TerminalPositionResponse.self)
                createdId = body.id
                #expect(body.ticker == "AMZN")
                #expect(abs((body.sharesNeeded ?? 0) - 1100) < 1e-9)
            }
            try await send(app, .POST, "v1/terminal-positions", token: user.token, body: TerminalFixtures.vg()) { res in
                #expect(res.status == .created)
            }
            try await send(app, .GET, "v1/terminal-positions?ticker=amzn", token: user.token) { res in
                let body = try res.content.decode(TerminalPositionsListResponse.self)
                #expect(body.positions.map(\.ticker) == ["AMZN"])
                #expect(!body.currency.isEmpty)
            }
            try await send(app, .PATCH, "v1/terminal-positions/\(createdId)", token: user.token,
                           body: TerminalPositionUpdateRequest(terminalShareCount: 0))
            { res in
                let body = try res.content.decode(TerminalPositionResponse.self)
                #expect(body.scenarioError == "share_count_not_positive")
                #expect(body.sharesNeeded == nil)
            }
            try await send(app, .POST, "v1/terminal-positions/\(createdId)/duplicate", token: user.token) { res in
                #expect(res.status == .created)
            }
            var ids: [String] = []
            try await send(app, .GET, "v1/terminal-positions", token: user.token) { res in
                ids = try res.content.decode(TerminalPositionsListResponse.self).positions.map(\.id)
            }
            #expect(ids.count == 3)
            try await send(app, .PUT, "v1/terminal-positions/order", token: user.token,
                           body: TerminalPositionOrderRequest(ids: ids.reversed()))
            { res in
                let body = try res.content.decode(TerminalPositionsListResponse.self)
                #expect(body.positions.map(\.id) == ids.reversed())
            }
            try await send(app, .GET, "v1/terminal-positions/summary", token: user.token) { res in
                let body = try res.content.decode(TerminalPositionsSummaryResponse.self)
                #expect(body.positionCount == 3)
            }
            try await send(app, .DELETE, "v1/terminal-positions/\(createdId)", token: user.token) { res in
                #expect(res.status == .noContent)
            }
        }
    }

    @Test("Another user's row is 404 over HTTP")
    func otherUser() async throws {
        try await TerminalFixtures.withApp { app in
            let owner = try await TerminalFixtures.registerUser(app: app)
            let other = try await TerminalFixtures.registerUser(app: app)
            var id = ""
            try await send(app, .POST, "v1/terminal-positions", token: owner.token, body: TerminalFixtures.vg()) { res in
                id = try res.content.decode(TerminalPositionResponse.self).id
            }
            try await send(app, .DELETE, "v1/terminal-positions/\(id)", token: other.token) { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("Autobuys CRUD returns monthly equivalents and a total")
    func autobuys() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            var id = ""
            try await send(app, .POST, "v1/autobuys", token: user.token,
                           body: AutobuyCreateRequest(label: "Beat the SPY", amount: 50, cadence: .weekly))
            { res in
                #expect(res.status == .created)
                id = try res.content.decode(AutobuyResponse.self).id
            }
            try await send(app, .PATCH, "v1/autobuys/\(id)", token: user.token,
                           body: AutobuyUpdateRequest(cadence: .monthly))
            { res in
                let body = try res.content.decode(AutobuyResponse.self)
                #expect(body.monthlyEquivalent == 50)
            }
            try await send(app, .GET, "v1/autobuys", token: user.token) { res in
                let body = try res.content.decode(AutobuysListResponse.self)
                #expect(body.monthlyTotal == 50)
            }
            try await send(app, .DELETE, "v1/autobuys/\(id)", token: user.token) { res in
                #expect(res.status == .noContent)
            }
        }
    }

    @Test("A planning:read PAT cannot write positions or autobuys")
    func readOnlyPATCannotWrite() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let readOnly = try await mintPAT(app: app, userId: user.userId, scopes: [.planningRead])
            try await send(app, .GET, "v1/terminal-positions", token: readOnly) { res in
                #expect(res.status == .ok)
            }
            try await send(app, .POST, "v1/terminal-positions", token: readOnly, body: TerminalFixtures.amzn()) { res in
                #expect(res.status == .forbidden)
            }
            try await send(app, .DELETE, "v1/autobuys/\(UUID().uuidString)", token: readOnly) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("Numbers above the 1e18 cap are 422; two rows at the cap keep the summary finite")
    func capsInputs() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let tooBig = TerminalPositionCreateRequest(
                ticker: "BIG", terminalShareCount: 1, terminalMarketCap: 1, valueWanted: 1e19
            )
            try await send(app, .POST, "v1/terminal-positions", token: user.token, body: tooBig) { res in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("too large"))
            }
            let atCap = TerminalPositionCreateRequest(
                ticker: "CAP", sharesOutstanding: 1e18, terminalShareCount: 1e18, terminalMarketCap: 1e18,
                valueWanted: 1e18, sharesOwned: 1e18, currentSharePrice: 1e18
            )
            try await send(app, .POST, "v1/terminal-positions", token: user.token, body: atCap) { res in
                #expect(res.status == .created)
            }
            try await send(app, .POST, "v1/terminal-positions", token: user.token, body: atCap) { res in
                #expect(res.status == .created)
            }
            try await send(app, .POST, "v1/autobuys", token: user.token,
                           body: AutobuyCreateRequest(label: "big", amount: 1e19, cadence: .weekly))
            { res in
                #expect(res.status == .unprocessableEntity)
            }
            try await send(app, .GET, "v1/terminal-positions/summary", token: user.token) { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(TerminalPositionsSummaryResponse.self)
                #expect(body.totalValueWanted.isFinite)
                #expect(body.totalGapValueAtTerminal.isFinite)
                #expect((body.totalCapitalAtTodayPrice ?? 0).isFinite)
                #expect(body.monthlyAutobuyTotal.isFinite)
            }
        }
    }
}
