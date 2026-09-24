import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Owner-managed public links to a percent-only view of a portfolio.
///
/// Scope is a path segment rather than a query parameter — a portfolio UUID,
/// or `all` for every actual portfolio the caller owns — so GET, POST and
/// DELETE are encoded identically by every client.
struct PortfolioShareController: RouteCollection {
    static let allScope = "all"

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let read = protected.grouped(ScopeRequirementMiddleware(.portfolioRead)).grouped("portfolio", "share-links")
        let write = protected.grouped(ScopeRequirementMiddleware(.portfolioWrite)).grouped("portfolio", "share-links")
        read.get(":scope", use: status)
        write.post(":scope", use: create)
        write.delete(":scope", use: revoke)
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
        if let link = try await activeLink(owner, on: req.db) {
            link.revokedAt = Date()
            try await link.save(on: req.db)
        }
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

    private func activeLink(_ owner: OwnerScope, on db: any Database) async throws -> PortfolioShareLink? {
        let query = PortfolioShareLink.query(on: db)
            .filter(\.$userId == owner.userId)
            .filter(\.$revokedAt == nil)
        if let listId = owner.listId {
            query.filter(\.$portfolioListId == listId)
        } else {
            query.filter(\.$portfolioListId == nil)
        }
        return try await query.sort(\.$createdAt, .descending).first()
    }

    private func makeResponse(_ link: PortfolioShareLink, scope: String) -> PortfolioShareLinkResponse {
        PortfolioShareLinkResponse(
            slug: link.slug,
            url: "\(Self.baseURL())/p/\(link.slug)",
            scope: scope,
            createdAt: ISO8601DateFormatter().string(from: link.createdAt ?? Date())
        )
    }

    /// The web host that renders /p/{slug} — not the API host.
    static func baseURL() -> String {
        let raw = Environment.get("SHARE_PORTFOLIO_BASE_URL")?.trimmingCharacters(in: .whitespaces) ?? ""
        let base = raw.isEmpty ? "https://norviq.org" : raw
        return base.hasSuffix("/") ? String(base.dropLast()) : base
    }
}
