import Fluent
import Foundation
import Vapor

protocol EarningsNotificationPreferenceServicing: Sendable {
    func get(userId: UUID, on db: any Database) async throws -> EarningsNotificationPreferencesResponse
    func update(
        userId: UUID,
        payload: UpdateEarningsNotificationPreferencesRequest,
        on db: any Database
    ) async throws -> EarningsNotificationPreferencesResponse
}

struct DatabaseEarningsNotificationPreferenceService: EarningsNotificationPreferenceServicing {
    func get(userId: UUID, on db: any Database) async throws -> EarningsNotificationPreferencesResponse {
        let preference = try await EarningsNotificationPreference.query(on: db)
            .filter(\.$userId == userId)
            .first()
        return .init(enabled: preference?.enabled ?? true)
    }

    func update(
        userId: UUID,
        payload: UpdateEarningsNotificationPreferencesRequest,
        on db: any Database
    ) async throws -> EarningsNotificationPreferencesResponse {
        if let existing = try await EarningsNotificationPreference.query(on: db)
            .filter(\.$userId == userId)
            .first()
        {
            existing.enabled = payload.enabled
            try await existing.save(on: db)
            return .init(enabled: existing.enabled)
        }

        let created = EarningsNotificationPreference(userId: userId, enabled: payload.enabled)
        try await created.save(on: db)
        return .init(enabled: created.enabled)
    }
}

extension Application {
    private struct EarningsNotificationPreferenceServiceKey: StorageKey {
        typealias Value = any EarningsNotificationPreferenceServicing
    }

    var earningsNotificationPreferenceService: any EarningsNotificationPreferenceServicing {
        get {
            guard let service = storage[EarningsNotificationPreferenceServiceKey.self] else {
                fatalError("EarningsNotificationPreferenceServicing not configured")
            }
            return service
        }
        set {
            storage[EarningsNotificationPreferenceServiceKey.self] = newValue
        }
    }
}

extension Request {
    var earningsNotificationPreferenceService: any EarningsNotificationPreferenceServicing {
        application.earningsNotificationPreferenceService
    }
}
