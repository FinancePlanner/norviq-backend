import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Receives Plaid item/transaction webhooks. Verified with a shared secret
/// header (constant-time), mirroring the Finnhub webhook. A full Plaid JWT/JWK
/// verification is a follow-up; the shared secret keeps the endpoint closed
/// until then.
struct PlaidWebhookController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("webhooks", "plaid").post(use: receive)
    }

    private struct PlaidWebhookPayload: Content {
        let webhookType: String
        let webhookCode: String
        let itemId: String

        enum CodingKeys: String, CodingKey {
            case webhookType = "webhook_type"
            case webhookCode = "webhook_code"
            case itemId = "item_id"
        }
    }

    @Sendable
    func receive(req: Request) async throws -> HTTPStatus {
        try verifySecret(req)
        let payload = try req.content.decode(PlaidWebhookPayload.self)

        guard let connection = try await BankConnection.query(on: req.db)
            .filter(\.$provider == BankProviderKind.plaid.rawValue)
            .filter(\.$providerItemId == payload.itemId)
            .first()
        else {
            // Unknown item — acknowledge so Plaid stops retrying.
            return .ok
        }

        switch payload.webhookCode {
        case "SYNC_UPDATES_AVAILABLE", "INITIAL_UPDATE", "HISTORICAL_UPDATE", "DEFAULT_UPDATE":
            let provider = try req.bankProviderRegistry.provider(for: .plaid)
            _ = try? await provider.sync(connection: connection, on: req)
        case "PENDING_EXPIRATION", "ERROR", "USER_PERMISSION_REVOKED":
            connection.status = BankConnectionStatus.reauthRequired.rawValue
            connection.lastSyncStatus = "reauth_required"
            connection.lastSyncError = payload.webhookCode
            try await connection.save(on: req.db)
        default:
            break
        }
        return .ok
    }

    private func verifySecret(_ req: Request) throws {
        let configured = Environment.get("PLAID_WEBHOOK_SECRET")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configured, !configured.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "PLAID_WEBHOOK_SECRET is not configured.")
        }
        let provided = req.headers.first(name: "X-Plaid-Webhook-Secret")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let provided, !provided.isEmpty else {
            throw Abort(.unauthorized, reason: "Missing Plaid webhook secret.")
        }
        guard ConstantTime.equals(provided, configured) else {
            throw Abort(.unauthorized, reason: "Invalid Plaid webhook secret.")
        }
    }
}
