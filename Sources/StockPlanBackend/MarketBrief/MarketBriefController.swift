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
    }

    func show(req: Request) async throws -> Response {
        let language = MarketBriefLanguage.resolve(req.query[String.self, at: "lang"]).rawValue
        let brief: MarketBriefResponse
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
        let response = try await brief.encodeResponse(for: req)
        response.headers.replaceOrAdd(name: .cacheControl, value: "private, max-age=300")
        return response
    }
}
