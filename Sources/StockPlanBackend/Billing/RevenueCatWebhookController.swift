import Vapor

struct RevenueCatWebhookController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("webhooks", "revenuecat").post(use: receive)
    }

    @Sendable
    func receive(req: Request) async throws -> HTTPStatus {
        try verifySecret(req)
        let rawPayload = req.body.string ?? ""
        let payload = try req.content.decode(RevenueCatWebhookPayload.self)
        try await req.application.billingService.process(
            event: payload.event,
            rawPayload: rawPayload,
            on: req.db
        )
        return .ok
    }
}

private extension RevenueCatWebhookController {
    func verifySecret(_ req: Request) throws {
        let configured = Environment.get("REVENUECAT_WEBHOOK_SECRET")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configured, !configured.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "REVENUECAT_WEBHOOK_SECRET is not configured.")
        }
        let provided = req.headers.first(name: .authorization)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let provided, !provided.isEmpty else {
            throw Abort(.unauthorized, reason: "Missing Authorization header.")
        }
        guard provided == configured else {
            throw Abort(.unauthorized, reason: "Invalid webhook secret.")
        }
    }
}
