import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Receives Plaid item/transaction webhooks. Verified with Plaid's JWT scheme:
/// the `Plaid-Verification` header is an ES256 JWS whose key is fetched by `kid`
/// and cached, and whose `request_body_sha256` claim must match the raw body.
struct PlaidWebhookController: RouteCollection {
    private let verifier = PlaidWebhookVerifier()

    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("webhooks", "plaid").post(use: receive)
    }

    private struct PlaidWebhookPayload: Codable {
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
        let rawBody = try await Self.collectRawBody(req)
        try await verify(req, rawBody: rawBody)

        guard let payload = try? JSONDecoder().decode(PlaidWebhookPayload.self, from: rawBody) else {
            throw Abort(.badRequest, reason: "Malformed Plaid webhook payload.")
        }

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

    private func verify(_ req: Request, rawBody: Data) async throws {
        guard let config = req.application.plaidConfiguration else {
            throw PlaidWebhookVerificationError.notConfigured
        }
        guard let token = req.headers.first(name: "Plaid-Verification")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
        else {
            throw PlaidWebhookVerificationError.missingHeader
        }
        try await verifier.verify(
            header: token,
            rawBody: rawBody,
            client: PlaidClient(config: config),
            cache: req.application.plaidWebhookKeyCache,
            on: req
        )
    }

    private static func collectRawBody(_ req: Request) async throws -> Data {
        if let buffer = req.body.data {
            return Data(buffer: buffer)
        }
        let collected = try await req.body.collect(max: 1_000_000).get()
        guard let buffer = collected else { return Data() }
        return Data(buffer: buffer)
    }
}
