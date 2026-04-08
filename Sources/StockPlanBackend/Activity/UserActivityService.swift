import Fluent
import Foundation
import Vapor
import StockPlanShared

protocol UserActivityService: Sendable {
    func getActivities(userId: UUID, limit: Int, on db: any Database) async throws -> [UserActivityResponse]
    func recordActivity(
        userId: UUID,
        type: UserActivityType,
        title: String,
        subtitle: String,
        amount: Double?,
        isGrowth: Bool,
        symbol: String,
        on db: any Database
    ) async throws
}

struct DatabaseUserActivityService: UserActivityService {
    func getActivities(userId: UUID, limit: Int, on db: any Database) async throws -> [UserActivityResponse] {
        let activities = try await DatabaseUserActivityRepository().list(userId: userId, limit: limit, on: db)
        return activities.map { activity in
            UserActivityResponse(
                id: activity.id ?? UUID(),
                userId: activity.userId,
                type: activity.type,
                title: activity.title,
                subtitle: activity.subtitle,
                amount: activity.amount,
                isGrowth: activity.isGrowth,
                symbol: activity.symbol,
                createdAt: activity.createdAt ?? Date()
            )
        }
    }

    func recordActivity(
        userId: UUID,
        type: UserActivityType,
        title: String,
        subtitle: String,
        amount: Double?,
        isGrowth: Bool,
        symbol: String,
        on db: any Database
    ) async throws {
        let activity = UserActivity(
            userId: userId,
            type: type,
            title: title,
            subtitle: subtitle,
            amount: amount,
            isGrowth: isGrowth,
            symbol: symbol
        )
        try await DatabaseUserActivityRepository().create(activity, on: db)
    }
}

extension Application {
    private struct UserActivityServiceKey: StorageKey {
        typealias Value = any UserActivityService
    }

    var userActivityService: any UserActivityService {
        get {
            storage[UserActivityServiceKey.self] ?? DatabaseUserActivityService()
        }
        set {
            storage[UserActivityServiceKey.self] = newValue
        }
    }
}

extension Request {
    var userActivityService: any UserActivityService {
        application.userActivityService
    }
}
