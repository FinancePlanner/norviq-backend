import Vapor
import Fluent
import JWT
import Crypto
import Foundation

protocol AuthService: Sendable {
    func register(email: String, password: String, on req: Request) async throws -> AuthResponse
    func login(email: String, password: String, on req: Request) async throws -> AuthResponse
    func currentUser(from req: Request) async throws -> AuthUserResponse
    func forgotPassword(email: String, on req: Request) async throws -> AuthForgotPasswordResponse
    func resendResetCode(email: String, on req: Request) async throws -> AuthForgotPasswordResponse
    func resetPassword(email: String, code: String, newPassword: String, on req: Request) async throws -> HTTPStatus
    func refresh(using refreshToken: String, on req: Request) async throws -> AuthResponse
}

struct DefaultAuthService: AuthService {
    let repo: any AuthRepository

    func register(email: String, password: String, on req: Request) async throws -> AuthResponse {
        let normalizedEmail = normalizeEmail(email)
        try validateEmail(normalizedEmail)
        try validatePassword(password)

        if try await repo.findUser(email: normalizedEmail, on: req.db) != nil {
            throw Abort(.conflict, reason: "Email already registered")
        }

        let hash = try await req.password.hash(password)
        let user = try await repo.createUser(email: normalizedEmail, passwordHash: hash, on: req.db)
        return try await makeAuthResponse(for: user, on: req)
    }

    func login(email: String, password: String, on req: Request) async throws -> AuthResponse {
        let normalizedEmail = normalizeEmail(email)
        try validateEmail(normalizedEmail)
        try validatePassword(password)

        guard let user = try await repo.findUser(email: normalizedEmail, on: req.db) else {
            throw Abort(.unauthorized, reason: "Invalid email or password")
        }

        let isValid = try await req.password.verify(password, created: user.passwordHash)
        guard isValid else {
            throw Abort(.unauthorized, reason: "Invalid email or password")
        }

        return try await makeAuthResponse(for: user, on: req)
    }

    func currentUser(from req: Request) async throws -> AuthUserResponse {
        let token = try req.auth.require(SessionToken.self)
        guard let user = try await repo.findUser(id: token.userId, on: req.db) else {
            throw Abort(.unauthorized, reason: "User not found")
        }
        return AuthUserResponse(id: user.id?.uuidString ?? "", email: user.email)
    }

    func forgotPassword(email: String, on req: Request) async throws -> AuthForgotPasswordResponse {
        try await issueResetCode(email: email, on: req)
    }

    func resendResetCode(email: String, on req: Request) async throws -> AuthForgotPasswordResponse {
        try await issueResetCode(email: email, on: req)
    }

    func resetPassword(email: String, code: String, newPassword: String, on req: Request) async throws -> HTTPStatus {
        let normalizedEmail = normalizeEmail(email)
        try validateEmail(normalizedEmail)
        try validatePassword(newPassword)

        guard let user = try await repo.findUser(email: normalizedEmail, on: req.db), let userId = user.id else {
            throw Abort(.unauthorized, reason: "Invalid reset code")
        }

        let now = Date()
        let codeHash = hashToken(code)

        guard let resetToken = try await repo.findValidPasswordResetToken(
            userId: userId,
            codeHash: codeHash,
            now: now,
            on: req.db
        ) else {
            throw Abort(.unauthorized, reason: "Invalid reset code")
        }

        user.passwordHash = try await req.password.hash(newPassword)
        try await user.save(on: req.db)
        try await repo.markPasswordResetTokenUsed(resetToken, usedAt: now, on: req.db)

        return .noContent
    }

    func refresh(using refreshToken: String, on req: Request) async throws -> AuthResponse {
        let tokenHash = hashToken(refreshToken)
        let now = Date()

        guard let storedToken = try await repo.findValidRefreshToken(tokenHash: tokenHash, now: now, on: req.db) else {
            throw Abort(.unauthorized, reason: "Invalid refresh token")
        }

        guard let user = try await repo.findUser(id: storedToken.userId, on: req.db) else {
            throw Abort(.unauthorized, reason: "User not found")
        }

        try await repo.revokeRefreshToken(storedToken, revokedAt: now, on: req.db)
        return try await makeAuthResponse(for: user, on: req)
    }

    // MARK: - Internals

    private func makeAuthResponse(for user: User, on req: Request) async throws -> AuthResponse {
        guard let userId = user.id else {
            throw Abort(.internalServerError, reason: "User id missing")
        }

        let expiresIn = jwtExpiresInSeconds(from: req)
        let expiration = ExpirationClaim(value: Date().addingTimeInterval(TimeInterval(expiresIn)))
        let payload = SessionToken(userId: userId, exp: expiration)
        let token = try await req.jwt.sign(payload)

        let (refresh, refreshExpiresIn) = try await issueRefreshToken(userId: userId, on: req)

        return AuthResponse(
            token: token,
            userId: userId,
            expiresIn: expiresIn,
            refreshToken: refresh,
            refreshExpiresIn: refreshExpiresIn
        )
    }

    private func issueResetCode(email: String, on req: Request) async throws -> AuthForgotPasswordResponse {
        let normalizedEmail = normalizeEmail(email)
        try validateEmail(normalizedEmail)

        guard let user = try await repo.findUser(email: normalizedEmail, on: req.db), let userId = user.id else {
            return AuthForgotPasswordResponse(message: "If the account exists, a reset code has been sent.", resetCode: nil)
        }

        let code = generateResetCode()
        let codeHash = hashToken(code)
        let expiresAt = Date().addingTimeInterval(15 * 60)

        try await repo.createPasswordResetToken(userId: userId, codeHash: codeHash, expiresAt: expiresAt, on: req.db)

        let shouldReturnCode = (Environment.get("AUTH_RESET_RETURN_CODE") ?? "false").lowercased() == "true"
        let responseCode = shouldReturnCode ? code : nil

        let message = MailMessage(
            to: normalizedEmail,
            subject: "Your StockPlan reset code",
            body: "Use this code to reset your password: \(code)"
        )
        try await req.application.mailer.send(message, on: req)

        return AuthForgotPasswordResponse(
            message: "If the account exists, a reset code has been sent.",
            resetCode: responseCode
        )
    }

    private func issueRefreshToken(userId: UUID, on req: Request) async throws -> (String, Int) {
        let expiresIn = refreshExpiresInSeconds(from: req)
        let rawToken = generateOpaqueToken()
        let tokenHash = hashToken(rawToken)
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))

        try await repo.createRefreshToken(userId: userId, tokenHash: tokenHash, expiresAt: expiresAt, on: req.db)
        return (rawToken, expiresIn)
    }

    private func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func validateEmail(_ email: String) throws {
        if email.isEmpty || !email.contains("@") {
            throw Abort(.badRequest, reason: "Invalid email")
        }
    }

    private func validatePassword(_ password: String) throws {
        if password.count < 8 {
            throw Abort(.badRequest, reason: "Password must be at least 8 characters")
        }
    }

    private func jwtExpiresInSeconds(from req: Request) -> Int {
        if let value = Environment.get("JWT_EXPIRES_IN_SECONDS"), let seconds = Int(value) {
            return seconds
        }
        return 60 * 60 * 24 * 7
    }

    private func refreshExpiresInSeconds(from req: Request) -> Int {
        if let value = Environment.get("JWT_REFRESH_EXPIRES_IN_SECONDS"), let seconds = Int(value) {
            return seconds
        }
        return 60 * 60 * 24 * 30
    }

    private func generateResetCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    private func generateOpaqueToken(length: Int = 32) -> String {
        let bytes = (0..<length).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func hashToken(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension Application {
    private struct AuthServiceKey: StorageKey {
        typealias Value = any AuthService
    }

    var authService: any AuthService {
        get {
            guard let service = storage[AuthServiceKey.self] else {
                fatalError("AuthService not configured")
            }
            return service
        }
        set {
            storage[AuthServiceKey.self] = newValue
        }
    }
}
