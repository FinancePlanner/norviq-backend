import Fluent
import Foundation
import Vapor

/// Weekly digest routes.
///
/// `POST /v1/digest/unsubscribe` is public and always registered: a link in an
/// email already sent must keep working even if `DIGEST_ENABLED` is later
/// switched off. The token is the only credential, and the answer is the same
/// whether or not it matched, so it cannot be used to probe for tokens.
/// Everything else 404s while `DIGEST_ENABLED` is off.
struct DigestController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.grouped(RateLimitMiddleware(limit: 30, interval: 60, keyPrefix: "ratelimit:digest-unsubscribe"))
            .post("digest", "unsubscribe", use: unsubscribe)

        let protected = routes.grouped(DigestFeatureGate(), ScopedBearerAuthenticator(), SessionToken.guardMiddleware())

        let digests = protected.grouped("digests").grouped(ScopeRequirementMiddleware(.portfolioRead))
        digests.get(use: list)
        digests.get(":digestId", use: show)

        let preferences = protected.grouped("digest-preferences")
        preferences.grouped(ScopeRequirementMiddleware(.notificationsRead)).get(use: getPreferences)
        preferences.grouped(ScopeRequirementMiddleware(.notificationsWrite)).put(use: updatePreferences)
    }

    // MARK: - Digests

    @Sendable
    func list(req: Request) async throws -> DigestListResponse {
        let session = try req.auth.require(SessionToken.self)
        let rows = try await WeeklyDigest.query(on: req.db)
            .filter(\.$userId == session.userId)
            .filter(\.$payload != nil)
            .sort(\.$periodStart, .descending)
            .limit(12)
            .all()
        return try DigestListResponse(items: rows.compactMap { row in
            guard let id = row.id, let payload = try row.decodedPayload() else { return nil }
            return DigestSummary(
                id: id,
                periodStart: row.periodStart,
                periodEnd: row.periodEnd,
                status: row.status,
                headline: DigestComposer.headline(payload)
            )
        })
    }

    @Sendable
    func show(req: Request) async throws -> DigestResponse {
        let session = try req.auth.require(SessionToken.self)
        guard let id = req.parameters.get("digestId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid digest id.")
        }
        // Someone else's id answers exactly like a missing one.
        guard let row = try await WeeklyDigest.query(on: req.db)
            .filter(\.$id == id)
            .filter(\.$userId == session.userId)
            .first(),
            let payload = try row.decodedPayload()
        else { throw Abort(.notFound) }
        return DigestResponse(
            id: id,
            periodStart: row.periodStart,
            periodEnd: row.periodEnd,
            status: row.status,
            headline: DigestComposer.headline(payload),
            payload: payload,
            narrative: row.narrative,
            createdAt: row.createdAt
        )
    }

    // MARK: - Preferences

    @Sendable
    func getPreferences(req: Request) async throws -> DigestPreferencesResponse {
        let session = try req.auth.require(SessionToken.self)
        let row = try await DigestPreference.query(on: req.db).filter(\.$userId == session.userId).first()
        return Self.response(row)
    }

    @Sendable
    func updatePreferences(req: Request) async throws -> DigestPreferencesResponse {
        let session = try req.auth.require(SessionToken.self)
        let update = try req.content.decode(DigestPreferencesUpdate.self)
        try Self.validate(update)
        let row = try await DigestPreference.query(on: req.db).filter(\.$userId == session.userId).first()
            ?? DigestPreference(userId: session.userId)
        if let value = update.emailEnabled {
            row.emailEnabled = value
        }
        if let value = update.pushEnabled {
            row.pushEnabled = value
        }
        if let value = update.telegramEnabled {
            row.telegramEnabled = value
        }
        if let value = update.sentimentAlertsEnabled {
            row.sentimentAlertsEnabled = value
        }
        if let value = update.weekday {
            row.weekday = value
        }
        if let value = update.localHour {
            row.localHour = value
        }
        if let value = update.timezone {
            row.timezone = value
        }
        if let value = update.country {
            row.country = value.isEmpty ? nil : MacroCountry(query: value)?.rawValue
        }
        try await row.save(on: req.db)
        return Self.response(row)
    }

    static func validate(_ update: DigestPreferencesUpdate) throws {
        if let weekday = update.weekday, !(1 ... 7).contains(weekday) {
            throw Abort(.badRequest, reason: "weekday must be 1 (Monday) to 7 (Sunday).")
        }
        if let hour = update.localHour, !(0 ... 23).contains(hour) {
            throw Abort(.badRequest, reason: "localHour must be 0 to 23.")
        }
        if let zone = update.timezone, TimeZone(identifier: zone) == nil {
            throw Abort(.badRequest, reason: "timezone must be an IANA identifier, e.g. Europe/Lisbon.")
        }
        if let country = update.country, !country.isEmpty, MacroCountry(query: country) == nil {
            throw Abort(.badRequest, reason: "Unsupported country.")
        }
    }

    static func response(_ row: DigestPreference?) -> DigestPreferencesResponse {
        let row = row ?? DigestPreference(userId: UUID())
        return DigestPreferencesResponse(
            decided: row.id != nil,
            emailEnabled: row.emailEnabled,
            pushEnabled: row.pushEnabled,
            telegramEnabled: row.telegramEnabled,
            sentimentAlertsEnabled: row.sentimentAlertsEnabled,
            weekday: row.weekday,
            localHour: row.localHour,
            timezone: row.timezone,
            country: row.country
        )
    }

    // MARK: - Unsubscribe

    /// RFC 8058 one-click: mail providers POST `List-Unsubscribe=One-Click` to
    /// the URL in the header. Idempotent; turns off email only.
    @Sendable
    func unsubscribe(req: Request) async throws -> DigestUnsubscribeResponse {
        guard let token = req.query[String.self, at: "token"], !token.isEmpty, token.count <= 128 else {
            throw Abort(.badRequest, reason: "Missing token.")
        }
        if let row = try await DigestPreference.query(on: req.db).filter(\.$unsubscribeToken == token).first(),
           row.emailEnabled
        {
            row.emailEnabled = false
            try await row.save(on: req.db)
            req.logger.info("digest.unsubscribed user=\(row.userId)")
        }
        return DigestUnsubscribeResponse(unsubscribed: true)
    }
}

/// 404 while the feature is off. Read per request so tests can flip it.
struct DigestFeatureGate: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.application.digestConfig.enabled else { throw Abort(.notFound) }
        return try await next.respond(to: request)
    }
}
