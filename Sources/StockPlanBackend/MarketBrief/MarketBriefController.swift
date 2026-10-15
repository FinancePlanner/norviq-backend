import Foundation
import StockPlanShared
import Vapor

/// `GET /v1/market/brief`. Same for every caller, so it sits in the
/// `market:read` group: iOS calls it with the user's session, and the web
/// calls it with its `PUBLIC_API_TOKEN` personal access token, including for
/// logged-out visitors on the landing page. Nothing is unauthenticated.
struct MarketBriefController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        protected.grouped("market", "brief")
            .grouped(ScopeRequirementMiddleware(.marketRead))
            .get(use: show)

        // The push opt-in is the user's own setting, so it carries the
        // notification scopes rather than market:read.
        let notifications = protected.grouped("market", "brief", "notifications")
        notifications.grouped(ScopeRequirementMiddleware(.notificationsRead))
            .get(use: notificationPreferences)
        notifications.grouped(ScopeRequirementMiddleware(.notificationsWrite))
            .put(use: updateNotificationPreferences)
    }

    @Sendable
    func notificationPreferences(req: Request) async throws -> MarketBriefNotificationPreferences {
        let session = try req.auth.require(SessionToken.self)
        return try await req.application.marketBriefNotificationPreferenceService.get(userId: session.userId, on: req.db)
    }

    @Sendable
    func updateNotificationPreferences(req: Request) async throws -> MarketBriefNotificationPreferences {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(MarketBriefNotificationPreferences.self)
        return try await req.application.marketBriefNotificationPreferenceService.update(
            userId: session.userId,
            payload: payload,
            on: req.db
        )
    }

    func show(req: Request) async throws -> Response {
        let language = MarketBriefLanguage.resolve(req.query[String.self, at: "lang"]).rawValue
        var brief: MarketBriefResponse
        if !req.application.marketBriefEnabled {
            brief = .empty(language: language, enabled: false)
        } else if let rawSlot = req.query[String.self, at: "slot"] {
            guard let slot = MarketBriefSlot(rawValue: rawSlot) else {
                throw Abort(.badRequest, reason: "slot must be morning or evening")
            }
            guard let date = req.query[String.self, at: "date"], date.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil else {
                throw Abort(.badRequest, reason: "date must be yyyy-MM-dd when slot is given")
            }
            guard let found = try await req.application.marketBriefRepository.find(
                tradingDate: date, slot: slot, language: language, on: req.db
            ) else {
                throw Abort(.notFound, reason: "No market brief for that date and slot.")
            }
            brief = found
        } else {
            brief = try await req.application.marketBriefRepository.latest(language: language, on: req.db)
                ?? .empty(language: language, enabled: true)
        }
        if let tradingDate = brief.tradingDate, let slot = brief.slot {
            let previous = try await req.application.marketBriefRepository.previous(
                tradingDate: tradingDate, slot: slot, language: language, on: req.db
            )
            brief = brief.with(previous: previous)
        }
        let response = try await brief.encodeResponse(for: req)
        response.headers.replaceOrAdd(name: .cacheControl, value: "private, max-age=300")
        return response
    }
}

extension MarketBriefResponse {
    /// Stored payloads never carry `previous`; it is worked out per request.
    func with(previous: MarketBriefRef?) -> MarketBriefResponse {
        MarketBriefResponse(
            enabled: enabled,
            tradingDate: tradingDate,
            slot: slot,
            language: language,
            greeting: greeting,
            groups: groups,
            items: items,
            generatedAt: generatedAt,
            degraded: degraded,
            previous: previous
        )
    }
}
