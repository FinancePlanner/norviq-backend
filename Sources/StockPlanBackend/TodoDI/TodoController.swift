import Fluent
import Vapor

struct TodoController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let todos = routes
            .grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
            .grouped("todos")

        todos.get(use: self.index)
        todos.post(use: self.create)
        todos.group(":todoID") { todo in
            todo.delete(use: self.delete)
        }
    }

    @Sendable
    func index(req: Request) async throws -> [TodoDTO] {
        let token = try req.auth.require(SessionToken.self)
        return try await Todo.owned(by: token.userId, on: req.db)
            .all()
            .map { $0.toDTO() }
    }

    @Sendable
    func create(req: Request) async throws -> TodoDTO {
        let token = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(TodoDTO.self)
        let todo = try await Todo.create(title: payload.title, userId: token.userId, on: req.db)
        return todo.toDTO()
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let token = try req.auth.require(SessionToken.self)
        guard
            let todoID = req.parameters.get("todoID", as: UUID.self),
            let todo = try await Todo.find(todoID, userId: token.userId, on: req.db)
        else {
            throw Abort(.notFound)
        }

        try await todo.delete(on: req.db)
        return .noContent
    }
}
