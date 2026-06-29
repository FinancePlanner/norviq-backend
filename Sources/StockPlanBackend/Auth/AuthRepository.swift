import Crypto
import Fluent
import Foundation
import Vapor

struct OAuthFlowDraft {
    let provider: String
    let state: String
    let nonce: String
    let codeVerifier: String
    let redirectURI: String
    let purpose: String
    let userId: UUID?
    let expiresAt: Date
}

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
    func findLatestActivePasswordResetToken(userId: UUID, now: Date, on db: any Database) async throws -> PasswordResetToken?
    func countRecentPasswordResetTokens(userId: UUID, since: Date, on db: any Database) async throws -> Int
    func savePasswordResetToken(_ token: PasswordResetToken, on db: any Database) async throws
    func markPasswordResetTokenUsed(_ token: PasswordResetToken, usedAt: Date, on db: any Database) async throws

    func createRefreshToken(userId: UUID, tokenHash: String, expiresAt: Date, on db: any Database) async throws
    func findValidRefreshToken(tokenHash: String, now: Date, on db: any Database) async throws -> RefreshToken?
    func revokeRefreshToken(_ token: RefreshToken, revokedAt: Date, on db: any Database) async throws

    func createOAuthFlow(_ draft: OAuthFlowDraft, on db: any Database) async throws -> OAuthFlow
    func findValidOAuthFlow(id: UUID, provider: String, now: Date, on db: any Database) async throws -> OAuthFlow?
    func markOAuthFlowUsed(_ flow: OAuthFlow, usedAt: Date, on db: any Database) async throws

    func findOAuthIdentity(provider: String, providerUserID: String, on db: any Database) async throws -> OAuthIdentity?
    func findOAuthIdentity(userId: UUID, provider: String, on db: any Database) async throws -> OAuthIdentity?
    func listOAuthIdentities(userId: UUID, on db: any Database) async throws -> [OAuthIdentity]
    func createOAuthIdentity(
        userId: UUID,
        provider: String,
        providerUserID: String,
        email: String?,
        emailVerified: Bool,
        on db: any Database
    ) async throws -> OAuthIdentity

    func createMFAChallenge(
        userId: UUID,
        purpose: String,
        channel: String,
        destination: String,
        codeHash: String,
        expiresAt: Date,
        lastSentAt: Date,
        on db: any Database
    ) async throws -> MFAChallenge
    func findMFAChallenge(id: UUID, on db: any Database) async throws -> MFAChallenge?
    func invalidateActiveMFAChallenges(userId: UUID, purpose: String, consumedAt: Date, on db: any Database) async throws
    func saveMFAChallenge(_ challenge: MFAChallenge, on db: any Database) async throws
}

struct DatabaseAuthRepository: AuthRepository {
    private let encryptionService: any UserPIIEncrypting

    init() {
        if let service = try? UserPIIEncryptionBootstrap.fromProcessEnvironment(
            logger: Logger(label: "auth.repository.default-encryption"),
            isProduction: false
        ) {
            encryptionService = service
        } else {
            encryptionService = AESGCMUserPIIEncryptionService(
                activeKeyID: "dev-default",
                activeKey: SymmetricKey(data: Data(repeating: 0x2A, count: 32)),
                previousKeys: [:]
            )
        }
    }

    init(encryptionService: any UserPIIEncrypting) {
        self.encryptionService = encryptionService
    }

    func findUser(email: String, on db: any Database) async throws -> User? {
        guard let user = try await User.query(on: db).filter(\.$email == email).first() else {
            return nil
        }
        try user.hydrateProtectedFields(using: encryptionService)
        return user
    }

    func findUser(username: String, on db: any Database) async throws -> User? {
        guard let user = try await User.query(on: db).filter(\.$username == username).first() else {
            return nil
        }
        try user.hydrateProtectedFields(using: encryptionService)
        return user
    }

    func findUser(id: UUID, on db: any Database) async throws -> User? {
        guard let user = try await User.find(id, on: db) else {
            return nil
        }
        try user.hydrateProtectedFields(using: encryptionService)
        return user
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
        try user.encryptProtectedFields(using: encryptionService)
        try await user.save(on: db)
        try user.hydrateProtectedFields(using: encryptionService)
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

    func findLatestActivePasswordResetToken(userId: UUID, now: Date, on db: any Database) async throws -> PasswordResetToken? {
        try await PasswordResetToken.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$usedAt == nil)
            .filter(\.$expiresAt > now)
            .sort(\.$createdAt, .descending)
            .first()
    }

    func countRecentPasswordResetTokens(userId: UUID, since: Date, on db: any Database) async throws -> Int {
        try await PasswordResetToken.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$createdAt >= since)
            .count()
    }

    func savePasswordResetToken(_ token: PasswordResetToken, on db: any Database) async throws {
        try await token.save(on: db)
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

    func createOAuthFlow(_ draft: OAuthFlowDraft, on db: any Database) async throws -> OAuthFlow {
        let flow = OAuthFlow(
            provider: draft.provider,
            state: draft.state,
            nonce: draft.nonce,
            codeVerifier: draft.codeVerifier,
            redirectURI: draft.redirectURI,
            purpose: draft.purpose,
            userId: draft.userId,
            expiresAt: draft.expiresAt
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

    func findOAuthIdentity(userId: UUID, provider: String, on db: any Database) async throws -> OAuthIdentity? {
        try await OAuthIdentity.query(on: db)
            .filter(\.$user.$id == userId)
            .filter(\.$provider == provider)
            .first()
    }

    func listOAuthIdentities(userId: UUID, on db: any Database) async throws -> [OAuthIdentity] {
        try await OAuthIdentity.query(on: db)
            .filter(\.$user.$id == userId)
            .all()
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

    func createMFAChallenge(
        userId: UUID,
        purpose: String,
        channel: String,
        destination: String,
        codeHash: String,
        expiresAt: Date,
        lastSentAt: Date,
        on db: any Database
    ) async throws -> MFAChallenge {
        let challenge = MFAChallenge(
            userId: userId,
            purpose: purpose,
            channel: channel,
            destination: destination,
            codeHash: codeHash,
            expiresAt: expiresAt,
            lastSentAt: lastSentAt
        )
        try await challenge.save(on: db)
        return challenge
    }

    func findMFAChallenge(id: UUID, on db: any Database) async throws -> MFAChallenge? {
        try await MFAChallenge.find(id, on: db)
    }

    func invalidateActiveMFAChallenges(userId: UUID, purpose: String, consumedAt: Date, on db: any Database) async throws {
        let active = try await MFAChallenge.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$purpose == purpose)
            .filter(\.$consumedAt == nil)
            .all()

        for challenge in active {
            challenge.consumedAt = consumedAt
            try await challenge.save(on: db)
        }
    }

    func saveMFAChallenge(_ challenge: MFAChallenge, on db: any Database) async throws {
        try await challenge.save(on: db)
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
