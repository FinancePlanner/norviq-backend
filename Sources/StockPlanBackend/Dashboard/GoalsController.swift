import Vapor
import Fluent
import StockPlanShared
import Foundation

struct GoalsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let goals = protected.grouped("goals")
        
        goals.get(use: index)
        goals.post(use: create)
        goals.get(":id", use: show)
        goals.patch(":id", use: update)
        goals.delete(":id", use: delete)
    }

    @Sendable
    func index(req: Request) async throws -> [GoalResponse] {
        let session = try req.auth.require(SessionToken.self)
        let goals = try await Goal.owned(by: session.userId, on: req.db)
            .sort(\.$createdAt, .descending)
            .all()
        return goals.map { $0.toDTO() }
    }

    @Sendable
    func create(req: Request) async throws -> GoalResponse {
        let session = try req.auth.require(SessionToken.self)
        let requestDTO = try req.content.decode(GoalRequest.self)
        let goal = try await Goal.create(title: requestDTO.title, userId: session.userId, on: req.db)
        return goal.toDTO()
    }

    @Sendable
    func show(req: Request) async throws -> GoalResponse {
        let session = try req.auth.require(SessionToken.self)
        guard let id = req.parameters.get("id", as: UUID.self),
              let goal = try await Goal.find(id, userId: session.userId, on: req.db) else {
            throw Abort(.notFound)
        }
        return goal.toDTO()
    }

    @Sendable
    func update(req: Request) async throws -> GoalResponse {
        let session = try req.auth.require(SessionToken.self)
        let requestDTO = try req.content.decode(GoalRequest.self)
        guard let id = req.parameters.get("id", as: UUID.self),
              let goal = try await Goal.find(id, userId: session.userId, on: req.db) else {
            throw Abort(.notFound)
        }
        goal.title = requestDTO.title
        try await goal.save(on: req.db)
        return goal.toDTO()
    }

    @Sendable
    func delete(req: Request) async throws -> EmptyAPIResponse {
        let session = try req.auth.require(SessionToken.self)
        guard let id = req.parameters.get("id", as: UUID.self),
              let goal = try await Goal.find(id, userId: session.userId, on: req.db) else {
            throw Abort(.notFound)
        }
        try await goal.delete(on: req.db)
        return EmptyAPIResponse()
    }
}

extension Goal {
    func toDTO() -> GoalResponse {
        let formatter = ISO8601DateFormatter()
        return GoalResponse(
            id: id!.uuidString,
            title: title,
            createdAt: createdAt.map { formatter.string(from: $0) },
            updatedAt: updatedAt.map { formatter.string(from: $0) }
        )
    }
}
