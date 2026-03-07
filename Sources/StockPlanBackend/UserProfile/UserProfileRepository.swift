import Fluent
import Foundation

protocol UserProfileRepository: Sendable {
    func find(id: UUID, on db: any Database) async throws -> User?
    func find(email: String, on db: any Database) async throws -> User?
    func find(username: String, on db: any Database) async throws -> User?
    func save(_ user: User, on db: any Database) async throws
    func delete(_ user: User, on db: any Database) async throws
}

struct DatabaseUserProfileRepository: UserProfileRepository {
    func find(id: UUID, on db: any Database) async throws -> User? {
        try await User.find(id, on: db)
    }

    func find(email: String, on db: any Database) async throws -> User? {
        try await User.query(on: db)
            .filter(\.$email == email)
            .first()
    }

    func find(username: String, on db: any Database) async throws -> User? {
        try await User.query(on: db)
            .filter(\.$username == username)
            .first()
    }

    func save(_ user: User, on db: any Database) async throws {
        try await user.save(on: db)
    }

    func delete(_ user: User, on db: any Database) async throws {
        try await user.delete(on: db)
    }
}
