import Fluent
import Foundation
import JWT
import JWTKit
import Vapor

struct SessionToken: JWTPayload, Authenticatable {
    let userId: UUID
    let exp: ExpirationClaim
    /// Issued-at. JWTKit encodes dates as fractional seconds, so this keeps
    /// sub-second precision. Optional because tokens minted before
    /// v1.4.1 carry none; those keep working until the user's first revocation.
    let iat: IssuedAtClaim?

    init(userId: UUID, exp: ExpirationClaim, iat: IssuedAtClaim? = nil) {
        self.userId = userId
        self.exp = exp
        self.iat = iat
    }

    func verify(using _: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }

    /// Shadows JWT's `JWTPayload.authenticator()` for this type, so every
    /// `SessionToken.authenticator()` in the route tree also checks revocation.
    static func authenticator() -> any AsyncAuthenticator {
        SessionTokenAuthenticator()
    }

    /// Whether `revokeAllTokens` has run since this token was issued. One
    /// primary-key lookup. A missing user is left to the handler, as before.
    func isCurrent(on db: any Database) async throws -> Bool {
        guard let user = try await User.find(userId, on: db),
              let validAfter = user.sessionsValidAfter
        else { return true }
        guard let issuedAt = iat?.value else { return false }
        return issuedAt >= validAfter
    }
}

/// `SessionToken.authenticator()`: verifies the JWT, then refuses it when the
/// user's sessions were revoked after it was issued. A refused token simply
/// does not log in, so the guard middleware answers 401 as for any bad token.
struct SessionTokenAuthenticator: JWTAuthenticator {
    typealias Payload = SessionToken

    func authenticate(jwt: SessionToken, for request: Request) async throws {
        guard try await jwt.isCurrent(on: request.db) else { return }
        request.auth.login(jwt)
    }
}
