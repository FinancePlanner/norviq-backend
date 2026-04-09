import Fluent
import Foundation
import Vapor

protocol AuthRepository: Sendable {
    func findUser(email: String, on db: any Database) async throws -> User?
    func findUser(username: String, on db: any Database) async throws -> User?
    func findUser(id: UUID, on db: any Database) async throws -> User?
    func createUser(
        username: String,
        email: String,
        passwordHash: String,
        dateOfBirth: Date,
        on db: any Database
    ) async throws -> User

    func createPasswordResetToken(userId: UUID, codeHash: String, expiresAt: Date, on db: any Database) async throws
    func findValidPasswordResetToken(userId: UUID, codeHash: String, now: Date, on db: any Database) async throws -> PasswordResetToken?
    func markPasswordResetTokenUsed(_ token: PasswordResetToken, usedAt: Date, on db: any Database) async throws

    func createRefreshToken(userId: UUID, tokenHash: String, expiresAt: Date, on db: any Database) async throws
    func findValidRefreshToken(tokenHash: String, now: Date, on db: any Database) async throws -> RefreshToken?
    func revokeRefreshToken(_ token: RefreshToken, revokedAt: Date, on db: any Database) async throws

    func createOAuthFlow(
        provider: String,
        state: String,
        nonce: String,
        codeVerifier: String,
        redirectURI: String,
        expiresAt: Date,
        on db: any Database
    ) async throws -> OAuthFlow
    func findValidOAuthFlow(id: UUID, provider: String, now: Date, on db: any Database) async throws -> OAuthFlow?
    func markOAuthFlowUsed(_ flow: OAuthFlow, usedAt: Date, on db: any Database) async throws

    func findOAuthIdentity(provider: String, providerUserID: String, on db: any Database) async throws -> OAuthIdentity?
    func createOAuthIdentity(
        userId: UUID,
        provider: String,
        providerUserID: String,
        email: String?,
        emailVerified: Bool,
        on db: any Database
    ) async throws -> OAuthIdentity
}

struct DatabaseAuthRepository: AuthRepository {
    func findUser(email: String, on db: any Database) async throws -> User? {
        try await User.query(on: db).filter(\.$email == email).first()
    }

    func findUser(username: String, on db: any Database) async throws -> User? {
        try await User.query(on: db).filter(\.$username == username).first()
    }

    func findUser(id: UUID, on db: any Database) async throws -> User? {
        try await User.find(id, on: db)
    }

    func createUser(
        username: String = UUID().uuidString.replacingOccurrences(of: "-", with: "_"),
        email: String,
        passwordHash: String,
        dateOfBirth: Date = Date(timeIntervalSince1970: 946_684_800),
        on db: any Database
    ) async throws -> User {
        let user = User(
            email: email,
            passwordHash: passwordHash,
            username: username,
            dateOfBirth: dateOfBirth
        )
        try await user.save(on: db)
        return user
    }

    func createPasswordResetToken(userId: UUID, codeHash: String, expiresAt: Date, on db: any Database) async throws {
        let token = PasswordResetToken(userId: userId, codeHash: codeHash, expiresAt: expiresAt)
        try await token.save(on: db)
    }

    func findValidPasswordResetToken(userId: UUID, codeHash: String, now: Date, on db: any Database) async throws -> PasswordResetToken? {
        try await PasswordResetToken.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$codeHash == codeHash)
            .filter(\.$usedAt == nil)
            .filter(\.$expiresAt > now)
            .sort(\.$createdAt, .descending)
            .first()
    }

    func markPasswordResetTokenUsed(_ token: PasswordResetToken, usedAt: Date, on db: any Database) async throws {
        token.usedAt = usedAt
        try await token.save(on: db)
    }

    func createRefreshToken(userId: UUID, tokenHash: String, expiresAt: Date, on db: any Database) async throws {
        let token = RefreshToken(userId: userId, tokenHash: tokenHash, expiresAt: expiresAt)
        try await token.save(on: db)
    }

    func findValidRefreshToken(tokenHash: String, now: Date, on db: any Database) async throws -> RefreshToken? {
        try await RefreshToken.query(on: db)
            .filter(\.$tokenHash == tokenHash)
            .filter(\.$revokedAt == nil)
            .filter(\.$expiresAt > now)
            .first()
    }

    func revokeRefreshToken(_ token: RefreshToken, revokedAt: Date, on db: any Database) async throws {
        token.revokedAt = revokedAt
        try await token.save(on: db)
    }

    func createOAuthFlow(
        provider: String,
        state: String,
        nonce: String,
        codeVerifier: String,
        redirectURI: String,
        expiresAt: Date,
        on db: any Database
    ) async throws -> OAuthFlow {
        let flow = OAuthFlow(
            provider: provider,
            state: state,
            nonce: nonce,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI,
            expiresAt: expiresAt
        )
        try await flow.save(on: db)
        return flow
    }

    func findValidOAuthFlow(id: UUID, provider: String, now: Date, on db: any Database) async throws -> OAuthFlow? {
        try await OAuthFlow.query(on: db)
            .filter(\.$id == id)
            .filter(\.$provider == provider)
            .filter(\.$usedAt == nil)
            .filter(\.$expiresAt > now)
            .first()
    }

    func markOAuthFlowUsed(_ flow: OAuthFlow, usedAt: Date, on db: any Database) async throws {
        flow.usedAt = usedAt
        try await flow.save(on: db)
    }

    func findOAuthIdentity(provider: String, providerUserID: String, on db: any Database) async throws -> OAuthIdentity? {
        try await OAuthIdentity.query(on: db)
            .filter(\.$provider == provider)
            .filter(\.$providerUserID == providerUserID)
            .first()
    }

    func createOAuthIdentity(
        userId: UUID,
        provider: String,
        providerUserID: String,
        email: String?,
        emailVerified: Bool,
        on db: any Database
    ) async throws -> OAuthIdentity {
        let identity = OAuthIdentity(
            userID: userId,
            provider: provider,
            providerUserID: providerUserID,
            email: email,
            emailVerified: emailVerified
        )
        try await identity.save(on: db)
        return identity
    }
}

extension Application {
    private struct AuthRepositoryKey: StorageKey {
        typealias Value = any AuthRepository
    }

    var authRepository: any AuthRepository {
        get {
            guard let repo = storage[AuthRepositoryKey.self] else {
                fatalError("AuthRepository not configured")
            }
            return repo
        }
        set {
            storage[AuthRepositoryKey.self] = newValue
        }
    }
}
