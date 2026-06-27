import Fluent
import Foundation
import StockPlanShared
import Vapor

struct UserActivityRecord {
    let userId: UUID
    let type: UserActivityType
    let title: String
    let subtitle: String
    let amount: Double?
    let isGrowth: Bool
    let symbol: String
    let referenceKey: String?
}

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
    func recordActivity(_ record: UserActivityRecord, on db: any Database) async throws
}

extension UserActivityService {
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
        try await recordActivity(
            UserActivityRecord(
                userId: userId,
                type: type,
                title: title,
                subtitle: subtitle,
                amount: amount,
                isGrowth: isGrowth,
                symbol: symbol,
                referenceKey: nil
            ),
            on: db
        )
    }
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
        try await recordActivity(
            UserActivityRecord(
                userId: userId,
                type: type,
                title: title,
                subtitle: subtitle,
                amount: amount,
                isGrowth: isGrowth,
                symbol: symbol,
                referenceKey: nil
            ),
            on: db
        )
    }

    func recordActivity(_ record: UserActivityRecord, on db: any Database) async throws {
        if let referenceKey = record.referenceKey {
            let existing = try await UserActivity.query(on: db)
                .filter(\.$userId == record.userId)
                .filter(\.$type == record.type)
                .filter(\.$referenceKey == referenceKey)
                .first()
            guard existing == nil else { return }
        }

        let activity = UserActivity(
            userId: record.userId,
            type: record.type,
            title: record.title,
            subtitle: record.subtitle,
            amount: record.amount,
            isGrowth: record.isGrowth,
            symbol: record.symbol,
            referenceKey: record.referenceKey
        )
        do {
            try await DatabaseUserActivityRepository().create(activity, on: db)
        } catch {
            if record.referenceKey != nil, String(reflecting: error).contains("idx_user_activities_unique_reference") {
                return
            }
            throw error
        }
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
