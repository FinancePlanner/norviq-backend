import Fluent
import Foundation
import StockPlanShared

enum NotificationEventPublisher {
    @discardableResult
    static func publish(
        userId: UUID,
        kind: NotificationEventKind,
        deduplicationKey: String,
        title: String,
        body: String,
        deepLink: String? = nil,
        payload: [String: String] = [:],
        on db: any Database
    ) async throws -> NotificationEventModel {
        if let existing = try await NotificationEventModel.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$deduplicationKey == deduplicationKey)
            .first()
        {
            return existing
        }
        let event = NotificationEventModel(
            userId: userId,
            kind: kind,
            deduplicationKey: deduplicationKey,
            title: title,
            body: body,
            deepLink: deepLink,
            payload: payload
        )
        do {
            try await event.create(on: db)
            return event
        } catch {
            if let existing = try await NotificationEventModel.query(on: db)
                .filter(\.$userId == userId)
                .filter(\.$deduplicationKey == deduplicationKey)
                .first()
            {
                return existing
            }
            throw error
        }
    }
}
