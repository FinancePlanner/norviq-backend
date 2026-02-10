import Foundation
import Vapor
import Fluent

enum TodoDIServiceError: Error {
    case invalidTitle
    case notFound
}

protocol TodoDIService: Sendable {
    func list(userId: UUID, on db: any Database) async throws -> [TodoResponse]
    func get(id: UUID, userId: UUID, on db: any Database) async throws -> TodoResponse
    func create(title: String, userId: UUID, on db: any Database) async throws -> TodoResponse
    func update(id: UUID, title: String, userId: UUID, on db: any Database) async throws -> TodoResponse
    func delete(id: UUID, userId: UUID, on db: any Database) async throws
}

struct DefaultTodoDIService: TodoDIService {
    let repo: any TodoDIRepository

    func list(userId: UUID, on db: any Database) async throws -> [TodoResponse] {
        let todos = try await repo.list(userId: userId, on: db)
        return try todos.map { try TodoResponse(from: $0) }
    }

    func get(id: UUID, userId: UUID, on db: any Database) async throws -> TodoResponse {
        guard let todo = try await repo.find(id: id, userId: userId, on: db) else {
            throw TodoDIServiceError.notFound
        }
        return try TodoResponse(from: todo)
    }

    func create(title: String, userId: UUID, on db: any Database) async throws -> TodoResponse {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw TodoDIServiceError.invalidTitle
        }

        let todo = try await repo.create(title: normalizedTitle, userId: userId, on: db)
        return try TodoResponse(from: todo)
    }

    func update(id: UUID, title: String, userId: UUID, on db: any Database) async throws -> TodoResponse {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw TodoDIServiceError.invalidTitle
        }

        guard let todo = try await repo.update(id: id, title: normalizedTitle, userId: userId, on: db) else {
            throw TodoDIServiceError.notFound
        }
        return try TodoResponse(from: todo)
    }

    func delete(id: UUID, userId: UUID, on db: any Database) async throws {
        let deleted = try await repo.delete(id: id, userId: userId, on: db)
        guard deleted else {
            throw TodoDIServiceError.notFound
        }
    }
}

extension Application {
    private struct TodoServiceKey: StorageKey {
        typealias Value = any TodoDIService
    }

    var todoDIService: any TodoDIService {
        get {
            guard let service = storage[TodoServiceKey.self] else {
                fatalError("TodoDIService not configured")
            }
            return service
        }
        set {
            storage[TodoServiceKey.self] = newValue
        }
    }
}
