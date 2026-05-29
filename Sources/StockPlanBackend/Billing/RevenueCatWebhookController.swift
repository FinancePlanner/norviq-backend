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
        guard RevenueCatWebhookController.constantTimeEquals(provided, configured) else {
            throw Abort(.unauthorized, reason: "Invalid webhook secret.")
        }
    }
}

extension RevenueCatWebhookController {
    /// Compares two secrets without a data-dependent early return.
    ///
    /// RevenueCat authenticates webhooks with the configured Authorization bearer value (it does
    /// not sign the body), so the shared secret is the only guard. Swift's `String ==` short-
    /// circuits on the first differing byte, which is a timing oracle for brute-forcing the secret.
    /// This folds every byte into the accumulator so the running time does not reveal how many
    /// leading bytes matched.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var diff = UInt8(a.count == b.count ? 0 : 1)
        let count = max(a.count, b.count)
        for i in 0 ..< count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            diff |= x ^ y
        }
        return diff == 0
    }
}
