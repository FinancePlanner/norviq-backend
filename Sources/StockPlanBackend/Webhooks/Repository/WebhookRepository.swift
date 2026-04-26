import Fluent
import Foundation

protocol WebhookRepository: Sendable {
    /// Creates a new webhook delivery record.
    func create(_ webhook: WebhookDelivery, on db: any Database) async throws -> WebhookDelivery

    /// Retrieves webhooks due for retry (status = pending and next_retry_at <= now), ordered by next_retry_at ascending.
    func findDue(limit: Int, on db: any Database) async throws -> [WebhookDelivery]

    /// Marks a webhook as successfully delivered.
    func markSent(_ webhook: WebhookDelivery, on db: any Database) async throws

    /// Marks a webhook as failed (transient), increments attempt count, and schedules next retry with exponential backoff.
    func markFailed(_ webhook: WebhookDelivery, error: String, on db: any Database) async throws

    /// Marks a webhook as exhausted (max attempts reached).
    func markExhausted(_ webhook: WebhookDelivery, on db: any Database) async throws

    /// Finds a webhook by its webhook key.
    func findByKey(_ key: String, on db: any Database) async throws -> WebhookDelivery?
}
