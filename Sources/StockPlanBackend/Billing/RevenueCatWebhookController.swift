import Crypto
import Vapor

struct RevenueCatWebhookController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("webhooks", "revenuecat").post(use: receive)
    }

    @Sendable
    func receive(req: Request) async throws -> HTTPStatus {
        let rawPayload = req.body.string ?? ""
        try verifySecret(req, rawPayload: rawPayload)
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
    static let revenueCatSignatureHeader = "X-RevenueCat-Webhook-Signature"
    static let signatureToleranceSeconds: TimeInterval = 300

    func verifySecret(_ req: Request, rawPayload: String) throws {
        // 1. HMAC validation takes precedence if REVENUECAT_HMAC_SECRET is configured
        if let hmacSecret = Environment.get("REVENUECAT_HMAC_SECRET")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !hmacSecret.isEmpty
        {
            let header = req.headers.first(name: Self.revenueCatSignatureHeader)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let header, !header.isEmpty else {
                throw Abort(.unauthorized, reason: "Missing signature header for HMAC validation.")
            }

            let parsed = try parseRevenueCatSignatureHeader(header)
            let now = Date().timeIntervalSince1970
            guard abs(now - TimeInterval(parsed.timestamp)) <= Self.signatureToleranceSeconds else {
                throw Abort(.unauthorized, reason: "Webhook signature timestamp is outside the allowed tolerance.")
            }

            let key = SymmetricKey(data: Data(hmacSecret.utf8))
            let signedPayload = "\(parsed.timestamp).\(rawPayload)"
            let computedHMAC = HMAC<SHA256>.authenticationCode(for: Data(signedPayload.utf8), using: key)
            let computedHex = Data(computedHMAC).map { String(format: "%02x", $0) }.joined()

            guard RevenueCatWebhookController.constantTimeEquals(parsed.signature, computedHex) else {
                throw Abort(.unauthorized, reason: "Invalid webhook signature.")
            }
            return
        }

        // 2. Fallback to legacy Authorization header
        let configured = Environment.get("REVENUECAT_WEBHOOK_SECRET")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configured, !configured.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "Neither REVENUECAT_HMAC_SECRET nor REVENUECAT_WEBHOOK_SECRET is configured.")
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

    func parseRevenueCatSignatureHeader(_ header: String) throws -> (timestamp: Int64, signature: String) {
        var timestamp: Int64?
        var signature: String?

        for part in header.split(separator: ",") {
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            let key = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "t":
                timestamp = Int64(value)
            case "v1":
                signature = value
            default:
                continue
            }
        }

        guard let timestamp, let signature, !signature.isEmpty else {
            throw Abort(.unauthorized, reason: "Malformed webhook signature header.")
        }

        return (timestamp, signature.lowercased())
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
        ConstantTime.equals(lhs, rhs)
    }
}
