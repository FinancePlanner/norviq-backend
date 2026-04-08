import Fluent
import Foundation
import Vapor

protocol UserActivityRepository: Sendable {
    func list(userId: UUID, limit: Int, on db: any Database) async throws -> [UserActivity]
    func create(_ activity: UserActivity, on db: any Database) async throws
}

struct DatabaseUserActivityRepository: UserActivityRepository {
    func list(userId: UUID, limit: Int, on db: any Database) async throws -> [UserActivity] {
        try await UserActivity.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()
    }

    func create(_ activity: UserActivity, on db: any Database) async throws {
        try await activity.save(on: db)
    }
}

extension Application {
    private struct UserActivityRepositoryKey: StorageKey {
        typealias Value = any UserActivityRepository
    }

    var userActivityRepository: any UserActivityRepository {
        get {
            storage[UserActivityRepositoryKey.self] ?? DatabaseUserActivityRepository()
        }
        set {
            storage[UserActivityRepositoryKey.self] = newValue
        }
    }
}

extension Request {
    var userActivityRepository: any UserActivityRepository {
        application.userActivityRepository
    }
}
