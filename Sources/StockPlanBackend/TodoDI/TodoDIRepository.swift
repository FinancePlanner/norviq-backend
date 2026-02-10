import Fluent
import Vapor
import Foundation

protocol TodoDIRepository: Sendable {
    func list(userId: UUID, on db: any Database) async throws -> [Todo]
    func find(id: UUID, userId: UUID, on db: any Database) async throws -> Todo?
    func create(title: String, userId: UUID, on db: any Database) async throws -> Todo
    func update(id: UUID, title: String, userId: UUID, on db: any Database) async throws -> Todo?
    func delete(id: UUID, userId: UUID, on db: any Database) async throws -> Bool
}

struct DatabaseTodoDIRepository: TodoDIRepository {
    func list(userId: UUID, on db: any Database) async throws -> [Todo] {
        try await Todo.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$createdAt, .descending)
            .all()
    }

    func find(id: UUID, userId: UUID, on db: any Database) async throws -> Todo? {
        try await Todo.query(on: db)
            .filter(\.$id == id)
            .filter(\.$userId == userId)
            .first()
    }

    func create(title: String, userId: UUID, on db: any Database) async throws -> Todo {
        let todo = Todo(userId: userId, title: title)
        try await todo.save(on: db)
        return todo
    }

    func update(id: UUID, title: String, userId: UUID, on db: any Database) async throws -> Todo? {
        guard let todo = try await find(id: id, userId: userId, on: db) else {
            return nil
        }
        todo.title = title
        try await todo.save(on: db)
        return todo
    }

    func delete(id: UUID, userId: UUID, on db: any Database) async throws -> Bool {
        guard let todo = try await find(id: id, userId: userId, on: db) else {
            return false
        }
        try await todo.delete(on: db)
        return true
    }
}

extension Application {
    private struct TodoDIRepositoryKey: StorageKey {
        typealias Value = any TodoDIRepository
    }

    var todoDIRepository: any TodoDIRepository {
        get {
            guard let repo = storage[TodoDIRepositoryKey.self] else {
                fatalError("TodoDIRepository not configured")
            }
            return repo
        }
        set {
            storage[TodoDIRepositoryKey.self] = newValue
        }
    }
}
