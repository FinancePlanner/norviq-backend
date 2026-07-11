import Fluent
import Foundation
import JWTKit
import Vapor

/// Authenticates bearer tokens on route groups exposed to third-party clients:
/// opaque personal access tokens (and OAuth access tokens in a later phase) by
/// prefix, falling back to first-party SessionToken JWT verification for
/// everything else — mirroring `SessionToken.authenticator()`.
///
/// Use this INSTEAD of `SessionToken.authenticator()` on scoped groups (the JWT
/// authenticator throws on non-JWT bearers, so chaining both would 401 every
/// opaque token). Successful opaque auth logs in both a synthesized SessionToken
/// — existing handlers keep working unchanged — and a ScopeContext consumed by
/// ScopeRequirementMiddleware. Groups still using `SessionToken.authenticator()`
/// reject opaque tokens, which is the intended default.
struct ScopedBearerAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        guard bearer.token.hasPrefix(OpaqueToken.patPrefix) else {
            let session = try await request.jwt.verify(bearer.token, as: SessionToken.self)
            request.auth.login(session)
            return
        }

        let tokenHash = OpaqueToken.sha256Hex(bearer.token)
        guard
            let pat = try await PersonalAccessToken.query(on: request.db)
            .filter(\.$tokenHash == tokenHash)
            .first(),
            pat.isActive,
            let tokenId = pat.id
        else { return }

        try await touchLastUsed(pat, on: request)

        request.auth.login(SessionToken(
            userId: pat.userId,
            exp: ExpirationClaim(value: pat.expiresAt)
        ))
        try request.auth.login(ScopeContext(
            tokenId: tokenId,
            kind: .personalAccessToken,
            scopes: APIScope.parse(pat.scopes)
        ))
    }

    /// Updates last_used_at at most once per minute to avoid a write per request.
    private func touchLastUsed(_ pat: PersonalAccessToken, on request: Request) async throws {
        let now = Date()
        if let last = pat.lastUsedAt, now.timeIntervalSince(last) < 60 {
            return
        }
        pat.lastUsedAt = now
        try await pat.save(on: request.db)
    }
}
