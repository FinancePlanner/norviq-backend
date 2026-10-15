import Fluent
import Foundation
import Vapor

/// Consent to send a user's financial context to third-party AI providers
/// (Anthropic, OpenRouter and the models behind it). Stored as
/// `users.ai_data_consent_at`; set and withdrawn through `/v1/users/ai-consent`.
///
/// Enforcement sits behind `AI_CONSENT_ENFORCED` (default off). While off,
/// everything behaves as before. While on:
///   * user-initiated AI routes throw 403 `AI_CONSENT_REQUIRED`
///     (`require(userId:req:)`), whatever credential reached them, because the
///     data leaves through Norviq's providers either way;
///   * background AI work and Telegram are strict (`isAllowed(userId:on:)`):
///     no consent, no AI, and jobs log how many users they skipped;
///   * BYO-key users are gated the same way: the data still leaves.
///
/// Legacy iOS grace (`AI_CONSENT_LEGACY_IOS_GRACE`, default off): iOS 1.4.0
/// and older have no consent sheet and would only ever see a dead 403. While
/// the grace is on, a request that does not announce `ai-consent-v1` in
/// `X-StockPlan-Client-Capabilities` and comes from CFNetwork (the iOS HTTP
/// stack) is let through and counted (`ai_consent_legacy_grace_total`). Clients
/// that ship the sheet announce the capability and get the strict rule.
///
/// Not gated: MCP tools returning data to the client the user connected
/// themselves, and voice transcription (in-cluster Whisper).
enum AIConsent {
    static let requiredReason = "AI_CONSENT_REQUIRED"
    static let capabilityToken = "ai-consent-v1"

    static var isEnforced: Bool {
        envBool("AI_CONSENT_ENFORCED", default: false)
    }

    static var legacyIOSGrace: Bool {
        envBool("AI_CONSENT_LEGACY_IOS_GRACE", default: false)
    }

    static func consentedAt(userId: UUID, on db: any Database) async throws -> Date? {
        try await User.find(userId, on: db)?.aiDataConsentAt
    }

    /// Strict check for work with no client behind it (jobs, Telegram).
    static func isAllowed(userId: UUID, on db: any Database) async throws -> Bool {
        guard isEnforced else { return true }
        return try await consentedAt(userId: userId, on: db) != nil
    }

    /// Check for a user-initiated request; applies the legacy-iOS grace.
    static func isAllowed(userId: UUID, req: Request) async throws -> Bool {
        guard isEnforced else { return true }
        if try await consentedAt(userId: userId, on: req.db) != nil { return true }
        guard legacyIOSGrace, isLegacyIOSClient(req) else { return false }
        PrometheusMetrics.shared.recordAIConsentLegacyGrace()
        req.logger.info("ai_consent.legacy_grace user_id=\(userId.uuidString) path=\(req.url.path)")
        return true
    }

    /// Throws 403 `AI_CONSENT_REQUIRED` unless this request may run AI work.
    static func require(userId: UUID, req: Request) async throws {
        guard try await isAllowed(userId: userId, req: req) else {
            throw Abort(.forbidden, reason: requiredReason)
        }
    }

    /// An iOS build from before the consent sheet: CFNetwork, and no
    /// `ai-consent-v1` capability. Web, Telegram and jobs never match.
    static func isLegacyIOSClient(_ req: Request) -> Bool {
        guard !ClientCapabilities.has(capabilityToken, in: req) else { return false }
        return req.headers.first(name: .userAgent)?.contains("CFNetwork") == true
    }
}

/// `{"consentedAt": "<ISO8601>" | null}`. The key is always present, null
/// included, so clients can tell "never consented" from a missing field.
struct AIConsentResponse: Content, Equatable {
    let consentedAt: Date?

    enum CodingKeys: String, CodingKey {
        case consentedAt
    }

    init(consentedAt: Date?) {
        self.consentedAt = consentedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent(String.self, forKey: .consentedAt)
        consentedAt = try raw.map { value in
            guard let date = Self.formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .consentedAt, in: container, debugDescription: "Expected an ISO 8601 date"
                )
            }
            return date
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Formatted here rather than by the encoder's date strategy, so the
        // wire format does not depend on which encoder serialises it.
        try container.encode(consentedAt.map(Self.formatter.string(from:)), forKey: .consentedAt)
    }

    private static var formatter: ISO8601DateFormatter {
        ISO8601DateFormatter()
    }
}

struct AIConsentController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // Reading the flag is a settings read, same as GET /v1/users.
        routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
            .grouped(ScopeRequirementMiddleware(.settingsRead))
            .get("users", "ai-consent", use: show)

        // Granting or withdrawing consent is the user's own act, never an agent's.
        let firstParty = routes
            .grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
            .grouped(FirstPartyOnlyMiddleware())
        firstParty.post("users", "ai-consent", use: grant)
        firstParty.delete("users", "ai-consent", use: withdraw)
    }

    @Sendable
    func show(req: Request) async throws -> AIConsentResponse {
        let session = try req.auth.require(SessionToken.self)
        return try await AIConsentResponse(consentedAt: requireUser(session.userId, on: req.db).aiDataConsentAt)
    }

    @Sendable
    func grant(req: Request) async throws -> AIConsentResponse {
        let session = try req.auth.require(SessionToken.self)
        let user = try await requireUser(session.userId, on: req.db)
        // Granting again keeps the original timestamp: it records when the
        // user first agreed, which is what the privacy record needs.
        if user.aiDataConsentAt == nil {
            user.aiDataConsentAt = Date()
            try await user.save(on: req.db)
        }
        return AIConsentResponse(consentedAt: user.aiDataConsentAt)
    }

    @Sendable
    func withdraw(req: Request) async throws -> AIConsentResponse {
        let session = try req.auth.require(SessionToken.self)
        let user = try await requireUser(session.userId, on: req.db)
        if user.aiDataConsentAt != nil {
            user.aiDataConsentAt = nil
            try await user.save(on: req.db)
        }
        return AIConsentResponse(consentedAt: nil)
    }

    private func requireUser(_ userId: UUID, on db: any Database) async throws -> User {
        guard let user = try await User.find(userId, on: db) else {
            throw Abort(.unauthorized, reason: "User not found")
        }
        return user
    }
}
