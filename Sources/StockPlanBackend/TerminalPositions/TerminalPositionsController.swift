import Fluent
import Foundation
import StockPlanShared
import Vapor

extension TerminalPositionResponse: @retroactive Content {}
extension TerminalPositionCreateRequest: @retroactive Content {}
extension TerminalPositionUpdateRequest: @retroactive Content {}
extension TerminalPositionOrderRequest: @retroactive Content {}
extension TerminalPositionsListResponse: @retroactive Content {}
extension TerminalPositionsSummaryResponse: @retroactive Content {}
extension AutobuyResponse: @retroactive Content {}
extension AutobuyCreateRequest: @retroactive Content {}
extension AutobuyUpdateRequest: @retroactive Content {}
extension AutobuysListResponse: @retroactive Content {}

/// `/v1/terminal-positions` and `/v1/autobuys`. User-scoped; free for every
/// plan. AI suggestions live in `TerminalPositionsAIController`.
struct TerminalPositionsController: RouteCollection {
    private let service = TerminalPositionsService()

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())

        let positions = protected.grouped("terminal-positions")
        let readPositions = positions.grouped(ScopeRequirementMiddleware(.planningRead))
        let writePositions = positions.grouped(ScopeRequirementMiddleware(.planningWrite))
        readPositions.get(use: index)
        readPositions.get("summary", use: summary)
        writePositions.post(use: create)
        writePositions.put("order", use: reorder)
        writePositions.patch(":id", use: update)
        writePositions.delete(":id", use: delete)
        writePositions.post(":id", "duplicate", use: duplicate)

        let autobuys = protected.grouped("autobuys")
        autobuys.grouped(ScopeRequirementMiddleware(.planningRead)).get(use: listAutobuys)
        let writeAutobuys = autobuys.grouped(ScopeRequirementMiddleware(.planningWrite))
        writeAutobuys.post(use: createAutobuy)
        writeAutobuys.patch(":id", use: updateAutobuy)
        writeAutobuys.delete(":id", use: deleteAutobuy)
    }

    private func userId(_ req: Request) throws -> UUID {
        try req.auth.require(SessionToken.self).userId
    }

    private func id(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest, reason: "invalid id") }
        return id
    }

    @Sendable
    func index(req: Request) async throws -> TerminalPositionsListResponse {
        let user = try userId(req)
        let rows = try await service.list(userId: user, ticker: req.query[String.self, at: "ticker"], on: req.db)
        return try await TerminalPositionsListResponse(
            currency: service.currency(userId: user, on: req.db),
            positions: rows.map { $0.toResponse() }
        )
    }

    @Sendable
    func summary(req: Request) async throws -> TerminalPositionsSummaryResponse {
        try await service.summary(userId: userId(req), on: req.db)
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        let input = try req.content.decode(TerminalPositionCreateRequest.self)
        let row = try await service.create(userId: userId(req), input, on: req.db)
        return try await row.toResponse().encodeResponse(status: .created, for: req)
    }

    @Sendable
    func update(req: Request) async throws -> TerminalPositionResponse {
        let input = try req.content.decode(TerminalPositionUpdateRequest.self)
        return try await service.update(userId: userId(req), id: id(req), input, on: req.db).toResponse()
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        try await service.delete(userId: userId(req), id: id(req), on: req.db)
        return .noContent
    }

    @Sendable
    func duplicate(req: Request) async throws -> Response {
        let row = try await service.duplicate(userId: userId(req), id: id(req), on: req.db)
        return try await row.toResponse().encodeResponse(status: .created, for: req)
    }

    @Sendable
    func reorder(req: Request) async throws -> TerminalPositionsListResponse {
        let user = try userId(req)
        let input = try req.content.decode(TerminalPositionOrderRequest.self)
        let rows = try await service.reorder(userId: user, ids: input.ids, on: req.db)
        return try await TerminalPositionsListResponse(
            currency: service.currency(userId: user, on: req.db),
            positions: rows.map { $0.toResponse() }
        )
    }

    @Sendable
    func listAutobuys(req: Request) async throws -> AutobuysListResponse {
        let user = try userId(req)
        let rows = try await service.listAutobuys(userId: user, on: req.db)
        return try await AutobuysListResponse(
            currency: service.currency(userId: user, on: req.db),
            autobuys: rows.map { $0.toResponse() },
            monthlyTotal: TerminalPositionsService.monthlyTotal(rows)
        )
    }

    @Sendable
    func createAutobuy(req: Request) async throws -> Response {
        let input = try req.content.decode(AutobuyCreateRequest.self)
        let row = try await service.createAutobuy(userId: userId(req), input, on: req.db)
        return try await row.toResponse().encodeResponse(status: .created, for: req)
    }

    @Sendable
    func updateAutobuy(req: Request) async throws -> AutobuyResponse {
        let input = try req.content.decode(AutobuyUpdateRequest.self)
        return try await service.updateAutobuy(userId: userId(req), id: id(req), input, on: req.db).toResponse()
    }

    @Sendable
    func deleteAutobuy(req: Request) async throws -> HTTPStatus {
        try await service.deleteAutobuy(userId: userId(req), id: id(req), on: req.db)
        return .noContent
    }
}
