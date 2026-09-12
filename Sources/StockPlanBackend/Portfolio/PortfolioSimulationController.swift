import Foundation
import StockPlanShared
import Vapor

struct PortfolioSimulationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let read = protected.grouped(ScopeRequirementMiddleware(.planningRead))
        let write = protected.grouped(ScopeRequirementMiddleware(.planningWrite))

        read.get("portfolio", "simulations", use: list)
        read.get("portfolio", "simulations", ":simulationId", use: detail)

        write.post("portfolio", "simulations", use: create)
        write.put("portfolio", "simulations", ":simulationId", use: update)
        write.delete("portfolio", "simulations", ":simulationId", use: delete)
        // Computing is read-shaped but takes a body and hits live market data, which is
        // why the rebalancer's own `simulate` sits under the write scope too.
        write.post("portfolio", "simulations", "preview", use: preview)
        write.post("portfolio", "simulations", ":simulationId", "compute", use: compute)
    }

    @Sendable
    func list(req: Request) async throws -> PortfolioSimulationListResponse {
        let session = try req.auth.require(SessionToken.self)
        return try await req.portfolioSimulationService.list(
            userId: session.userId,
            limit: req.query["limit"] ?? 25,
            cursor: req.query["cursor"],
            on: req.db
        )
    }

    @Sendable
    func detail(req: Request) async throws -> PortfolioSimulation {
        let session = try req.auth.require(SessionToken.self)
        return try await req.portfolioSimulationService.detail(
            simulationId: identifier(req),
            userId: session.userId,
            on: req.db
        )
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let simulation = try await req.portfolioSimulationService.create(
            userId: session.userId,
            payload: req.content.decode(PortfolioSimulationUpsertRequest.self),
            req: req
        )
        let response = Response(status: .created)
        try response.content.encode(simulation)
        return response
    }

    @Sendable
    func update(req: Request) async throws -> PortfolioSimulation {
        let session = try req.auth.require(SessionToken.self)
        return try await req.portfolioSimulationService.update(
            simulationId: identifier(req),
            userId: session.userId,
            payload: req.content.decode(PortfolioSimulationUpsertRequest.self),
            req: req
        )
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        try await req.portfolioSimulationService.delete(
            simulationId: identifier(req),
            userId: session.userId,
            on: req.db
        )
        return .noContent
    }

    @Sendable
    func compute(req: Request) async throws -> PortfolioSimulationResult {
        let session = try req.auth.require(SessionToken.self)
        let payload = (try? req.content.decode(PortfolioSimulationComputeRequest.self))
            ?? PortfolioSimulationComputeRequest()
        return try await req.portfolioSimulationService.compute(
            simulationId: identifier(req),
            userId: session.userId,
            payload: payload,
            req: req
        )
    }

    @Sendable
    func preview(req: Request) async throws -> PortfolioSimulationResult {
        let session = try req.auth.require(SessionToken.self)
        return try await req.portfolioSimulationService.preview(
            userId: session.userId,
            payload: req.content.decode(PortfolioSimulationUpsertRequest.self),
            req: req
        )
    }

    private func identifier(_ req: Request) throws -> UUID {
        guard let raw = req.parameters.get("simulationId"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "A valid simulation id is required.")
        }
        return id
    }
}
