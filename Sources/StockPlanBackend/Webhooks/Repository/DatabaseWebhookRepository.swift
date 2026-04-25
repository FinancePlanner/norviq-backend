import Fluent
import Foundation

/// Database implementation of WebhookRepository using Fluent with PostgreSQL.
struct DatabaseWebhookRepository: WebhookRepository {
    func create(_ webhook: WebhookDelivery, on db: any Database) async throws -> WebhookDelivery {
        try await webhook.save(on: db)
        return webhook
    }

    func findDue(limit: Int, on db: any Database) async throws -> [WebhookDelivery] {
        try await WebhookDelivery.query(on: db)
            .filter(\.$status == .pending)
            .filter(\.$nextRetryAt <= Date())
            .sort(\.$nextRetryAt, .ascending)
            .limit(limit)
            .all()
    }

    func markSent(_ webhook: WebhookDelivery, on db: any Database) async throws {
        webhook.status = .success
        webhook.nextRetryAt = nil
        webhook.lastError = nil
        try await webhook.save(on: db)
    }

    func markFailed(_ webhook: WebhookDelivery, error: String, on db: any Database) async throws {
        webhook.attemptCount += 1
        webhook.lastError = error
        if webhook.attemptCount >= 5 {
            webhook.status = .exhausted
            webhook.nextRetryAt = nil
        } else {
            // Exponential backoff e.g.: 1m, 5m, 30m, 2h, 12h
            let backoff: [TimeInterval] = [60, 300, 1800, 7200, 43200]
            let delay = backoff[min(webhook.attemptCount - 1, backoff.count - 1)]
            webhook.nextRetryAt = Date().addingTimeInterval(delay)
        }
        try await webhook.save(on: db)
    }

    func markExhausted(_ webhook: WebhookDelivery, on db: any Database) async throws {
        webhook.status = .exhausted
        webhook.nextRetryAt = nil
        try await webhook.save(on: db)
    }

    func findByKey(_ key: String, on db: any Database) async throws -> WebhookDelivery? {
        try await WebhookDelivery.query(on: db)
            .filter(\.$webhookKey == key)
            .first()
    }
}
