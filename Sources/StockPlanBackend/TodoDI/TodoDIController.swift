import Vapor
import Fluent
import Foundation

struct TodoDIController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let todos = routes
            .grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
            .grouped("todos-di")

        todos.get(use: index)
        todos.post(use: create)

        todos.group(":todoID") { todo in
            todo.get(use: get)
            todo.put(use: update)
            todo.delete(use: delete)
        }
    }

    @Sendable
    func index(req: Request) async throws -> [TodoResponse] {
        let token = try req.auth.require(SessionToken.self)
        return try await req.application.todoDIService.list(userId: token.userId, on: req.db)
    }

    @Sendable
    func get(req: Request) async throws -> TodoResponse {
        let token = try req.auth.require(SessionToken.self)
        guard let id = req.parameters.get("todoID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid todo id")
        }

        do {
            return try await req.application.todoDIService.get(id: id, userId: token.userId, on: req.db)
        } catch TodoDIServiceError.notFound {
            throw Abort(.notFound)
        }
    }

    @Sendable
    func create(req: Request) async throws -> TodoResponse {
        let token = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(TodoCreateRequest.self)

        do {
            return try await req.application.todoDIService.create(title: payload.title, userId: token.userId, on: req.db)
        } catch TodoDIServiceError.invalidTitle {
            throw Abort(.badRequest, reason: "Title is required")
        }
    }

    @Sendable
    func update(req: Request) async throws -> TodoResponse {
        let token = try req.auth.require(SessionToken.self)
        guard let id = req.parameters.get("todoID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid todo id")
        }
        let payload = try req.content.decode(TodoUpdateRequest.self)

        do {
            return try await req.application.todoDIService.update(
                id: id,
                title: payload.title,
                userId: token.userId,
                on: req.db
            )
        } catch TodoDIServiceError.invalidTitle {
            throw Abort(.badRequest, reason: "Title is required")
        } catch TodoDIServiceError.notFound {
            throw Abort(.notFound)
        }
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let token = try req.auth.require(SessionToken.self)
        guard let id = req.parameters.get("todoID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid todo id")
        }

        do {
            try await req.application.todoDIService.delete(id: id, userId: token.userId, on: req.db)
            return .noContent
        } catch TodoDIServiceError.notFound {
            throw Abort(.notFound)
        }
    }
}
