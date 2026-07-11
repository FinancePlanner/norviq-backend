import Crypto
import Fluent
import Foundation
import Vapor

/// Core OAuth 2.1 authorization-server logic: PKCE verification, code/token
/// minting, and refresh rotation with reuse detection. Token secrets are opaque
/// (never JWTs) and stored only as SHA-256 hashes.
enum OAuthServerService {
    static let authorizationCodeTTL: TimeInterval = 600 // 10 min
    static let accessTokenTTL: TimeInterval = 3600 // 1 hour
    static let refreshTokenTTL: TimeInterval = 60 * 86400 // 60 days

    // MARK: PKCE

    /// Verifies an S256 PKCE code verifier against the stored challenge.
    static func verifyPKCE(codeVerifier: String, challenge: String) -> Bool {
        let digest = SHA256.hash(data: Data(codeVerifier.utf8))
        let computed = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return constantTimeEquals(computed, challenge)
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0 ..< ab.count {
            diff |= ab[i] ^ bb[i]
        }
        return diff == 0
    }

    // MARK: Authorization code

    /// Issues a plaintext authorization code and stores its hash on the flow,
    /// marking the flow approved.
    static func issueAuthorizationCode(for flow: OAuthAuthorizationFlow, on db: any Database) async throws -> String {
        let code = OpaqueToken.generate(prefix: "nvq_ac_")
        flow.codeHash = OpaqueToken.sha256Hex(code)
        flow.status = "approved"
        try await flow.save(on: db)
        return code
    }

    // MARK: Token pair

    struct IssuedTokens {
        let accessToken: String
        let refreshToken: String
        let accessExpiresIn: Int
        let scopes: [String]
    }

    static func issueTokens(
        clientID: String,
        userID: UUID,
        scopes: [String],
        on db: any Database
    ) async throws -> IssuedTokens {
        let access = OpaqueToken.generate(prefix: OpaqueToken.oauthAccessPrefix)
        let refresh = OpaqueToken.generate(prefix: OpaqueToken.oauthRefreshPrefix)
        let now = Date()
        let token = OAuthToken(
            clientID: clientID,
            userID: userID,
            accessTokenHash: OpaqueToken.sha256Hex(access),
            refreshTokenHash: OpaqueToken.sha256Hex(refresh),
            scopes: scopes,
            accessExpiresAt: now.addingTimeInterval(accessTokenTTL),
            refreshExpiresAt: now.addingTimeInterval(refreshTokenTTL)
        )
        try await token.save(on: db)
        return IssuedTokens(
            accessToken: access,
            refreshToken: refresh,
            accessExpiresIn: Int(accessTokenTTL),
            scopes: scopes
        )
    }

    /// Rotates a refresh token. If the presented token was already rotated
    /// (replay), the entire token family is revoked and nil is returned.
    static func rotateRefreshToken(
        rawRefreshToken: String,
        requestedScopes: [String]?,
        on db: any Database
    ) async throws -> IssuedTokens? {
        let hash = OpaqueToken.sha256Hex(rawRefreshToken)
        guard let existing = try await OAuthToken.query(on: db)
            .filter(\.$refreshTokenHash == hash)
            .first()
        else {
            return nil
        }

        // Reuse detection: a token already superseded or revoked means replay.
        if existing.replacedBy != nil || existing.revokedAt != nil {
            try await revokeFamily(from: existing, on: db)
            return nil
        }
        guard existing.refreshExpiresAt > Date() else { return nil }

        // Downscoping only: requested scopes must be a subset of the grant.
        var scopes = existing.scopes
        if let requested = requestedScopes, !requested.isEmpty {
            let granted = Set(existing.scopes)
            guard requested.allSatisfy({ granted.contains($0) }) else { return nil }
            scopes = requested
        }

        let issued = try await issueTokens(
            clientID: existing.clientID,
            userID: existing.userID,
            scopes: scopes,
            on: db
        )
        // Link the chain: mark old token replaced.
        let newHash = OpaqueToken.sha256Hex(issued.refreshToken)
        if let replacement = try await OAuthToken.query(on: db)
            .filter(\.$refreshTokenHash == newHash)
            .first()
        {
            existing.replacedBy = replacement.id
        }
        existing.revokedAt = Date()
        try await existing.save(on: db)
        return issued
    }

    private static func revokeFamily(from token: OAuthToken, on db: any Database) async throws {
        // Revoke every non-revoked token for this client+user (conservative:
        // a replay means the family is compromised).
        try await OAuthToken.query(on: db)
            .filter(\.$clientID == token.clientID)
            .filter(\.$userID == token.userID)
            .filter(\.$revokedAt == nil)
            .set(\.$revokedAt, to: Date())
            .update()
    }
}
