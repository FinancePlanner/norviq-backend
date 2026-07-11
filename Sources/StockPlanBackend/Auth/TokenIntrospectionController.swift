import Fluent
import Foundation
import Vapor

/// RFC 7662-shaped token introspection for the norviq-mcp service.
/// Authenticated with the MCP_INTROSPECTION_SECRET shared service secret —
/// never exposed to end users or third-party clients.
struct TokenIntrospectionController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("oauth").post("introspect", use: introspect)
    }

    func introspect(req: Request) async throws -> TokenIntrospectionResponse {
        try requireServiceSecret(req)

        let payload = try req.content.decode(TokenIntrospectionRequest.self)
        let tokenHash = OpaqueToken.sha256Hex(payload.token)

        if payload.token.hasPrefix(OpaqueToken.patPrefix) {
            guard let pat = try await PersonalAccessToken.query(on: req.db)
                .filter(\.$tokenHash == tokenHash).first(), pat.isActive
            else { return .inactive }
            return try await TokenIntrospectionResponse(
                active: true,
                sub: pat.userId.uuidString,
                scope: pat.scopes.joined(separator: " "),
                tokenType: ScopedTokenKind.personalAccessToken.rawValue,
                exp: Int(pat.expiresAt.timeIntervalSince1970),
                entitled: isEntitled(pat.userId, req)
            )
        }

        if payload.token.hasPrefix(OpaqueToken.oauthAccessPrefix) {
            guard let oauth = try await OAuthToken.query(on: req.db)
                .filter(\.$accessTokenHash == tokenHash).first(), oauth.accessActive
            else { return .inactive }
            return try await TokenIntrospectionResponse(
                active: true,
                sub: oauth.userID.uuidString,
                scope: oauth.scopes.joined(separator: " "),
                tokenType: ScopedTokenKind.oauthAccessToken.rawValue,
                exp: Int(oauth.accessExpiresAt.timeIntervalSince1970),
                entitled: isEntitled(oauth.userID, req)
            )
        }

        return .inactive
    }

    private func isEntitled(_ userID: UUID, _ req: Request) async throws -> Bool {
        do {
            try await req.usageCounterService.requirePremium(.mcpAccess, userId: userID, on: req.db)
            return true
        } catch is BillingUpgradeRequiredError {
            return false
        }
    }

    private func requireServiceSecret(_ req: Request) throws {
        guard
            let configured = Environment.get("MCP_INTROSPECTION_SECRET")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        else {
            throw Abort(.serviceUnavailable, reason: "Token introspection is not configured.")
        }
        guard
            let provided = req.headers.bearerAuthorization?.token,
            OpaqueToken.sha256Hex(provided) == OpaqueToken.sha256Hex(configured)
        else {
            throw Abort(.unauthorized, reason: "Invalid introspection credentials.")
        }
    }
}

struct TokenIntrospectionRequest: Content {
    let token: String
}

struct TokenIntrospectionResponse: Content {
    let active: Bool
    let sub: String?
    let scope: String?
    let tokenType: String?
    let exp: Int?
    let entitled: Bool?

    static let inactive = TokenIntrospectionResponse(
        active: false, sub: nil, scope: nil, tokenType: nil, exp: nil, entitled: nil
    )
}
