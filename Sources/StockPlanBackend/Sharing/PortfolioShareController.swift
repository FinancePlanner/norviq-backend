import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Owner-managed public links to a percent-only view of a portfolio.
///
/// Scope is a path segment rather than a query parameter Ã¢ÂÂ a portfolio UUID,
/// or `all` for every actual portfolio the caller owns Ã¢ÂÂ so GET, POST and
/// DELETE are encoded identically by every client.
struct PortfolioShareController: RouteCollection {
    static let allScope = "all"

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let read = protected.grouped(ScopeRequirementMiddleware(.portfolioRead)).grouped("portfolio", "share-links")
        let write = protected.grouped(ScopeRequirementMiddleware(.portfolioWrite)).grouped("portfolio", "share-links")
        read.get(use: list)
        read.get(":scope", use: status)
        write.post(":scope", use: create)
        write.delete(":scope", use: revoke)

        // Unauthenticated, so this keys by peer address, which, behind the
        // web app, is the web pod, not the visitor. It is a pod-wide ceiling on
        // quote fan-out; per-visitor limiting lives on the web /p/ route.
        routes.grouped(RateLimitMiddleware(limit: 600, interval: 60, keyPrefix: "ratelimit:public-share"))
            .grouped("public", "portfolio-shares")
            .get(":slug", use: publicShare)
    }

    @Sendable
    func publicShare(req: Request) async throws -> Response {
        guard let slug = req.parameters.get("slug"),
              let link = try await PortfolioShareLink.query(on: req.db)
              .filter(\.$slug == slug)
              .filter(\.$revokedAt == nil)
              .first()
        else {
            throw Abort(.notFound)
        }

        // Re-resolved on every read with the owner check, so a portfolio that
        // was deleted or changed hands stops being visible through an old link.
        let filter: ResolvedPortfolioFilter
        do {
            filter = try await PortfolioFilterResolver.resolve(
                requestedId: link.portfolioListId?.uuidString,
                userId: link.userId,
                ownerOnly: true,
                on: req
            )
        } catch let abort as any AbortError where abort.status == .notFound || abort.status == .forbidden {
            throw Abort(.notFound)
        }

        let valuation = try await PortfolioFilterResolver.loadValuation(filter, on: req)
        let snapshots = try await PortfolioValueSnapshot.query(on: req.db)
            .filter(\.$userId == filter.dataOwnerUserId)
            .filter(\.$portfolioListId ~~ filter.portfolioIds)
            .sort(\.$capturedOn)
            .all()
        let days = PortfolioPerformanceBuilder.days(from: snapshots, listIds: filter.portfolioIds)
        let changes = PortfolioPerformanceBuilder.changes(from: days, asOf: valuation.asOf)

        let dto = PublicPortfolioShareBuilder.build(
            valuation: valuation,
            changes: changes,
            asOf: PortfolioPerformanceBuilder.formatDay(valuation.asOf)
        )
        let response = try await dto.encodeResponse(for: req)
        response.headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=60")
        return response
    }

    /// Every active link the caller owns, across scopes, so a client showing
    /// one scope can still surface — and revoke — a link made from another.
    @Sendable
    func list(req: Request) async throws -> [PortfolioShareLinkResponse] {
        let session = try req.auth.require(SessionToken.self)
        return try await PortfolioShareLink.query(on: req.db)
            .filter(\.$userId == session.userId)
            .filter(\.$revokedAt == nil)
            .sort(\.$createdAt, .descending)
            .all()
            .map { makeResponse($0, scope: $0.portfolioListId?.uuidString ?? Self.allScope) }
    }

    @Sendable
    func status(req: Request) async throws -> PortfolioShareLinkStatusResponse {
        let owner = try await resolveOwnerScope(req)
        let link = try await activeLink(owner, on: req.db)
        return PortfolioShareLinkStatusResponse(link: link.map { makeResponse($0, scope: owner.scope) })
    }

    @Sendable
    func create(req: Request) async throws -> PortfolioShareLinkResponse {
        let owner = try await resolveOwnerScope(req)
        if let existing = try await activeLink(owner, on: req.db) {
            return makeResponse(existing, scope: owner.scope)
        }
        let link = PortfolioShareLink(
            userId: owner.userId,
            portfolioListId: owner.listId,
            slug: OpaqueToken.generate(prefix: "p", byteCount: 16)
        )
        try await link.save(on: req.db)
        return makeResponse(link, scope: owner.scope)
    }

    @Sendable
    func revoke(req: Request) async throws -> HTTPStatus {
        let owner = try await resolveOwnerScope(req)
        // Every active row, not just the newest: two clients racing on create
        // can leave duplicates, and "stop sharing" must mean all of them.
        try await activeLinksQuery(owner, on: req.db)
            .set(\.$revokedAt, to: Date())
            .update()
        return .noContent
    }

    // MARK: - Helpers

    private struct OwnerScope {
        let userId: UUID
        let listId: UUID?
        let scope: String
    }

    /// Only the owner may share a specific portfolio; `all` is always the
    /// caller's own actual portfolios.
    private func resolveOwnerScope(_ req: Request) async throws -> OwnerScope {
        let session = try req.auth.require(SessionToken.self)
        guard let scope = req.parameters.get("scope") else {
            throw Abort(.badRequest)
        }
        if scope == Self.allScope {
            return OwnerScope(userId: session.userId, listId: nil, scope: scope)
        }
        let filter = try await PortfolioFilterResolver.resolve(
            requestedId: scope, userId: session.userId, ownerOnly: true, on: req
        )
        return OwnerScope(userId: session.userId, listId: filter.portfolioId, scope: scope)
    }

    private func activeLinksQuery(_ owner: OwnerScope, on db: any Database) -> QueryBuilder<PortfolioShareLink> {
        let query = PortfolioShareLink.query(on: db)
            .filter(\.$userId == owner.userId)
            .filter(\.$revokedAt == nil)
        if let listId = owner.listId {
            query.filter(\.$portfolioListId == listId)
        } else {
            query.filter(\.$portfolioListId == nil)
        }
        return query
    }

    private func activeLink(_ owner: OwnerScope, on db: any Database) async throws -> PortfolioShareLink? {
        try await activeLinksQuery(owner, on: db).sort(\.$createdAt, .descending).first()
    }

    private func makeResponse(_ link: PortfolioShareLink, scope: String) -> PortfolioShareLinkResponse {
        PortfolioShareLinkResponse(
            slug: link.slug,
            url: "\(Self.baseURL())/p/\(link.slug)",
            scope: scope,
            createdAt: ISO8601DateFormatter().string(from: link.createdAt ?? Date())
        )
    }

    /// The web host that renders /p/{slug} Ã¢ÂÂ not the API host.
    static func baseURL() -> String {
        let raw = Environment.get("SHARE_PORTFOLIO_BASE_URL")?.trimmingCharacters(in: .whitespaces) ?? ""
        let base = raw.isEmpty ? "https://norviq.org" : raw
        return base.hasSuffix("/") ? String(base.dropLast()) : base
    }
}
