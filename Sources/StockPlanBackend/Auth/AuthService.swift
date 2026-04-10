import Crypto
import Fluent
import Foundation
import JWT
import StockPlanShared
import Vapor

protocol AuthService: Sendable {
    func register(
        username: String,
        email: String,
        password: String,
        confirmPassword: String,
        dateOfBirth: Date,
        on req: Request
    ) async throws -> AuthResponse
    func login(email: String, password: String, on req: Request) async throws -> AuthResponse
    func currentUser(from req: Request) async throws -> AuthUserResponse
    func forgotPassword(email: String, on req: Request) async throws -> AuthForgotPasswordResponse
    func resendResetCode(email: String, on req: Request) async throws -> AuthForgotPasswordResponse
    func resetPassword(email: String, code: String, newPassword: String, on req: Request)
        async throws -> HTTPStatus
    func refresh(using refreshToken: String, on req: Request) async throws -> AuthResponse
    func oauthStart(provider: OAuthProvider, redirectURI: String, on req: Request) async throws
        -> OAuthStartResponse
    func oauthExchange(
        provider: OAuthProvider,
        flowId: UUID,
        code: String,
        state: String,
        redirectURI: String,
        on req: Request
    ) async throws -> AuthResponse
}

struct DefaultAuthService: AuthService {
    let repo: any AuthRepository
    let oauthProviders: [OAuthProvider: any OAuthProviderClient]

    init(
        repo: any AuthRepository,
        oauthProviders: [OAuthProvider: any OAuthProviderClient] = [:]
    ) {
        self.repo = repo
        self.oauthProviders = oauthProviders
    }

    func register(
        username: String,
        email: String,
        password: String,
        confirmPassword: String,
        dateOfBirth: Date,
        on req: Request
    ) async throws -> AuthResponse {
        let normalizedUsername = normalizeUsername(username)
        let normalizedEmail = normalizeEmail(email)

        guard password == confirmPassword else {
            throw Abort(.badRequest, reason: "Password and confirm password do not match")
        }

        try validateUsername(normalizedUsername)
        try validateEmail(normalizedEmail)
        try validatePassword(password)
        try validateDateOfBirth(dateOfBirth)

        if try await repo.findUser(username: normalizedUsername, on: req.db) != nil {
            throw Abort(.conflict, reason: "Username already registered")
        }

        if try await repo.findUser(email: normalizedEmail, on: req.db) != nil {
            throw Abort(.conflict, reason: "Email already registered")
        }

        let hash = try req.password.hash(password)
        let user: User
        do {
            user = try await repo.createUser(
                username: normalizedUsername,
                email: normalizedEmail,
                passwordHash: hash,
                dateOfBirth: dateOfBirth,
                on: req.db
            )
        } catch {
            req.logger.error("Error creating user: \(String(reflecting: error))")
            throw error
        }
        return try await makeAuthResponse(for: user, on: req)
    }

    func login(email: String, password: String, on req: Request) async throws -> AuthResponse {
        let normalizedEmail = normalizeEmail(email)
        try validateEmail(normalizedEmail)
        try validatePassword(password)

        guard let user = try await repo.findUser(email: normalizedEmail, on: req.db) else {
            throw Abort(.unauthorized, reason: "Invalid email or password")
        }

        // 1. Check if the account is currently locked
        if let lockoutUntil = user.lockoutUntil, lockoutUntil > Date() {
            let timeRemaining = Int(lockoutUntil.timeIntervalSince(Date()) / 60)
            let message = timeRemaining > 0 
                ? "Account is temporarily locked due to multiple failed login attempts. Please try again in \(timeRemaining) minute(s)."
                : "Account is temporarily locked due to multiple failed login attempts. Please try again shortly."
            throw Abort(.forbidden, reason: message)
        }

        let isValid = try req.password.verify(password, created: user.passwordHash)
        
        if !isValid {
            // 2. Increment failed attempts and lock if necessary
            user.failedLoginAttempts += 1
            if user.failedLoginAttempts >= 5 {
                user.lockoutUntil = Date().addingTimeInterval(15 * 60) // 15 minutes
                req.logger.warning("Account locked for user \(user.email) until \(user.lockoutUntil!)")
            }
            try await persistUser(user, on: req)
            throw Abort(.unauthorized, reason: "Invalid email or password")
        }

        // 3. Reset failed attempts on successful login
        if user.failedLoginAttempts > 0 || user.lockoutUntil != nil {
            user.failedLoginAttempts = 0
            user.lockoutUntil = nil
            try await persistUser(user, on: req)
        }

        // 4. Check for email verification
        if !user.isVerified {
            // Note: For now, we allow login but might restrict certain features later, 
            // or enforce it strictly here if the client is ready for the verification flow.
            // req.logger.info("User \(user.email) logged in but is not verified.")
            // throw Abort(.forbidden, reason: "Please verify your email address before logging in.")
        }

        return try await makeAuthResponse(for: user, on: req)
    }

    func currentUser(from req: Request) async throws -> AuthUserResponse {
        let token = try req.auth.require(SessionToken.self)
        guard let user = try await repo.findUser(id: token.userId, on: req.db) else {
            throw Abort(.unauthorized, reason: "User not found")
        }
        return AuthUserResponse(
            id: user.id?.uuidString ?? "",
            username: responseUsername(for: user),
            email: user.email,
            dateOfBirth: responseDateOfBirth(for: user)
        )
    }

    func forgotPassword(email: String, on req: Request) async throws -> AuthForgotPasswordResponse {
        try await issueResetCode(email: email, on: req)
    }

    func resendResetCode(email: String, on req: Request) async throws -> AuthForgotPasswordResponse {
        try await issueResetCode(email: email, on: req)
    }

    func resetPassword(email: String, code: String, newPassword: String, on req: Request)
        async throws -> HTTPStatus {
        let normalizedEmail = normalizeEmail(email)
        try validateEmail(normalizedEmail)
        try validatePassword(newPassword)

        guard let user = try await repo.findUser(email: normalizedEmail, on: req.db),
            let userId = user.id
        else {
            throw Abort(.unauthorized, reason: "Invalid reset code")
        }

        let now = Date()
        let codeHash = hashToken(code)

        guard
            let resetToken = try await repo.findValidPasswordResetToken(
                userId: userId,
                codeHash: codeHash,
                now: now,
                on: req.db
            )
        else {
            throw Abort(.unauthorized, reason: "Invalid reset code")
        }

        user.passwordHash = try req.password.hash(newPassword)
        try await persistUser(user, on: req)
        try await repo.markPasswordResetTokenUsed(resetToken, usedAt: now, on: req.db)

        return .noContent
    }

    func refresh(using refreshToken: String, on req: Request) async throws -> AuthResponse {
        let tokenHash = hashToken(refreshToken)
        let now = Date()

        guard
            let storedToken = try await repo.findValidRefreshToken(
                tokenHash: tokenHash, now: now, on: req.db)
        else {
            throw Abort(.unauthorized, reason: "Invalid refresh token")
        }

        guard let user = try await repo.findUser(id: storedToken.userId, on: req.db) else {
            throw Abort(.unauthorized, reason: "User not found")
        }

        try await repo.revokeRefreshToken(storedToken, revokedAt: now, on: req.db)
        return try await makeAuthResponse(for: user, on: req)
    }

    func oauthStart(provider: OAuthProvider, redirectURI: String, on req: Request) async throws
        -> OAuthStartResponse {
        let normalizedRedirectURI = try normalizeRedirectURI(redirectURI)
        try validateRedirectURI(normalizedRedirectURI)

        let oauthProvider = try oauthProviderClient(for: provider)
        let state = randomURLSafeString(length: 32)
        let nonce = randomURLSafeString(length: 32)
        let codeVerifier = randomURLSafeString(length: 64)
        let codeChallenge = codeChallenge(for: codeVerifier)

        let authorizationURL = try oauthProvider.makeAuthorizationURL(
            context: OAuthAuthorizationContext(
                state: state,
                nonce: nonce,
                codeChallenge: codeChallenge,
                redirectURI: normalizedRedirectURI
            )
        )

        let expiresIn = 600
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let flow = try await repo.createOAuthFlow(
            provider: provider.rawValue,
            state: state,
            nonce: nonce,
            codeVerifier: codeVerifier,
            redirectURI: normalizedRedirectURI,
            expiresAt: expiresAt,
            on: req.db
        )

        guard let flowID = flow.id else {
            throw Abort(.internalServerError, reason: "OAuth flow id missing")
        }

        return OAuthStartResponse(
            flowId: flowID,
            authorizationURL: authorizationURL.absoluteString,
            expiresIn: expiresIn
        )
    }

    func oauthExchange(
        provider: OAuthProvider,
        flowId: UUID,
        code: String,
        state: String,
        redirectURI: String,
        on req: Request
    ) async throws -> AuthResponse {
        let oauthProvider = try oauthProviderClient(for: provider)
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedState = state.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRedirectURI = try normalizeRedirectURI(redirectURI)

        guard !normalizedCode.isEmpty else {
            throw Abort(.badRequest, reason: "OAuth authorization code is required")
        }
        guard !normalizedState.isEmpty else {
            throw Abort(.badRequest, reason: "OAuth state is required")
        }

        let now = Date()
        guard
            let flow = try await repo.findValidOAuthFlow(
                id: flowId,
                provider: provider.rawValue,
                now: now,
                on: req.db
            )
        else {
            throw Abort(.unauthorized, reason: "OAuth flow is invalid or expired")
        }

        guard flow.state == normalizedState else {
            throw Abort(.unauthorized, reason: "OAuth state mismatch")
        }

        guard flow.redirectURI == normalizedRedirectURI else {
            throw Abort(.unauthorized, reason: "OAuth redirect URI mismatch")
        }

        let identityInfo = try await oauthProvider.resolveIdentity(
            code: normalizedCode,
            redirectURI: normalizedRedirectURI,
            codeVerifier: flow.codeVerifier,
            nonce: flow.nonce,
            on: req
        )

        try await repo.markOAuthFlowUsed(flow, usedAt: now, on: req.db)

        if let existingIdentity = try await repo.findOAuthIdentity(
            provider: provider.rawValue,
            providerUserID: identityInfo.providerUserID,
            on: req.db
        ) {
            let userId = existingIdentity.$user.id
            guard let user = try await repo.findUser(id: userId, on: req.db) else {
                throw Abort(.unauthorized, reason: "OAuth identity user not found")
            }
            return try await makeAuthResponse(for: user, on: req)
        }

        let normalizedIdentityEmail = identityInfo.email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedIdentityEmail,
            try await repo.findUser(email: normalizedIdentityEmail, on: req.db) != nil {
            throw Abort(.conflict, reason: "ACCOUNT_EXISTS_LINK_REQUIRED")
        }
        let resolvedUserEmail =
            normalizedIdentityEmail
            ?? syntheticOAuthEmail(provider: provider, providerUserID: identityInfo.providerUserID)

        let oauthUsername = try await generateOAuthUsername(
            suggestedUsername: identityInfo.suggestedUsername,
            email: resolvedUserEmail,
            on: req
        )
        let oauthPassword = randomURLSafeString(length: 48)
        let oauthPasswordHash = try req.password.hash(oauthPassword)

        let user = try await repo.createUser(
            username: oauthUsername,
            email: resolvedUserEmail,
            passwordHash: oauthPasswordHash,
            dateOfBirth: defaultDateOfBirth(),
            on: req.db
        )

        guard let userID = user.id else {
            throw Abort(.internalServerError, reason: "User id missing after OAuth user creation")
        }

        _ = try await repo.createOAuthIdentity(
            userId: userID,
            provider: provider.rawValue,
            providerUserID: identityInfo.providerUserID,
            email: normalizedIdentityEmail,
            emailVerified: identityInfo.emailVerified,
            on: req.db
        )

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
            refreshExpiresIn: refreshExpiresIn,
            username: responseUsername(for: user),
            email: user.email,
            dateOfBirth: responseDateOfBirth(for: user)
        )
    }

    private func issueResetCode(email: String, on req: Request) async throws
        -> AuthForgotPasswordResponse {
        let normalizedEmail = normalizeEmail(email)
        try validateEmail(normalizedEmail)

        guard let user = try await repo.findUser(email: normalizedEmail, on: req.db),
            let userId = user.id
        else {
            return AuthForgotPasswordResponse(
                message: "If the account exists, a reset code has been sent.", resetCode: nil)
        }

        let code = generateResetCode()
        let codeHash = hashToken(code)
        let expiresAt = Date().addingTimeInterval(15 * 60)

        try await repo.createPasswordResetToken(
            userId: userId, codeHash: codeHash, expiresAt: expiresAt, on: req.db)

        let shouldReturnCode =
            (Environment.get("AUTH_RESET_RETURN_CODE") ?? "false").lowercased() == "true"
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

        try await repo.createRefreshToken(
            userId: userId, tokenHash: tokenHash, expiresAt: expiresAt, on: req.db)
        return (rawToken, expiresIn)
    }

    private func oauthProviderClient(for provider: OAuthProvider) throws -> any OAuthProviderClient {
        guard let client = oauthProviders[provider] else {
            throw Abort(
                .serviceUnavailable,
                reason: "OAuth provider '\(provider.rawValue)' is not configured")
        }
        return client
    }

    private func normalizeRedirectURI(_ redirectURI: String) throws -> String {
        let trimmed = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
            components.scheme != nil,
            components.host != nil || trimmed.contains("://"),
            let normalized = components.url?.absoluteString
        else {
            throw Abort(.badRequest, reason: "Invalid OAuth redirect URI")
        }
        return normalized
    }

    private func validateRedirectURI(_ redirectURI: String) throws {
        let allowlist = allowedRedirectURIs()
        guard !allowlist.isEmpty else {
            return
        }

        guard allowlist.contains(redirectURI) else {
            throw Abort(.badRequest, reason: "OAuth redirect URI is not allowed")
        }
    }

    private func allowedRedirectURIs() -> Set<String> {
        guard let raw = Environment.get("OAUTH_ALLOWED_REDIRECT_URIS") else {
            return []
        }

        return Set(
            raw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private func codeChallenge(for codeVerifier: String) -> String {
        let digest = SHA256.hash(data: Data(codeVerifier.utf8))
        let data = Data(digest)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func randomURLSafeString(length: Int) -> String {
        let byteCount = max(length, 32)
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: 0...255) }
        let raw = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        if raw.count >= length {
            return String(raw.prefix(length))
        }
        return raw + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private func generateOAuthUsername(
        suggestedUsername: String?,
        email: String,
        on req: Request
    ) async throws -> String {
        let emailPrefix = email.split(separator: "@").first.map(String.init) ?? "user"
        let normalizedSuggestedUsername: String? = {
            guard let suggestedUsername else { return nil }
            let trimmed = suggestedUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let source = normalizedSuggestedUsername ?? emailPrefix

        let sanitized =
            source
            .lowercased()
            .map { char -> Character in
                if char.isLetter || char.isNumber || char == "_" {
                    return char
                }
                return "_"
            }
        var base = String(sanitized)
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        if base.count < 4 {
            base += String(repeating: "0", count: 4 - base.count)
        }
        if base.count > 30 {
            base = String(base.prefix(30))
        }

        for attempt in 0..<10 {
            let candidate: String
            if attempt == 0 {
                candidate = base
            } else {
                let suffix = "\(Int.random(in: 1000...9999))"
                let maxBaseLength = max(4, 30 - suffix.count)
                let candidateBase = String(base.prefix(maxBaseLength))
                candidate = "\(candidateBase)\(suffix)"
            }

            if try await repo.findUser(username: candidate, on: req.db) == nil {
                return candidate
            }
        }

        return "user_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))"
    }

    private func syntheticOAuthEmail(provider: OAuthProvider, providerUserID: String) -> String {
        let normalizedProviderUserID =
            providerUserID
            .lowercased()
            .map { char -> Character in
                if char.isLetter || char.isNumber || char == "_" || char == "-" {
                    return char
                }
                return "_"
            }
        let sanitizedID = String(normalizedProviderUserID)
        return "oauth_\(provider.rawValue)_\(sanitizedID)@oauth.norviqa.invalid"
    }

    private func normalizeUsername(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func validateUsername(_ username: String) throws {
        let pattern = #"^[a-zA-Z0-9_]{4,30}$"#
        if username.range(of: pattern, options: .regularExpression) == nil {
            throw Abort(
                .badRequest,
                reason: "Username must be 4-30 characters (letters, numbers, underscore)")
        }
    }

    private func validateEmail(_ email: String) throws {
        if email.isEmpty || !email.contains("@") {
            throw Abort(.badRequest, reason: "Invalid email")
        }
    }

    private func validateDateOfBirth(_ dateOfBirth: Date) throws {
        if dateOfBirth > Date() {
            throw Abort(.badRequest, reason: "Date of birth cannot be in the future")
        }
    }

    private func persistUser(_ user: User, on req: Request) async throws {
        try user.encryptProtectedFields(using: req.userPIIEncryptionService)
        try await user.save(on: req.db)
        try user.hydrateProtectedFields(using: req.userPIIEncryptionService)
    }

    private func validatePassword(_ password: String) throws {
        if password.count < 8 {
            throw Abort(.badRequest, reason: "Password must be at least 8 characters long")
        }

        let uppercase = CharacterSet.uppercaseLetters
        let lowercase = CharacterSet.lowercaseLetters
        let digits = CharacterSet.decimalDigits
        let symbols = CharacterSet.punctuationCharacters.union(.symbols)

        guard password.unicodeScalars.contains(where: { uppercase.contains($0) }) else {
            throw Abort(.badRequest, reason: "Password must contain at least one uppercase letter")
        }
        guard password.unicodeScalars.contains(where: { lowercase.contains($0) }) else {
            throw Abort(.badRequest, reason: "Password must contain at least one lowercase letter")
        }
        guard password.unicodeScalars.contains(where: { digits.contains($0) }) else {
            throw Abort(.badRequest, reason: "Password must contain at least one number")
        }
        guard password.unicodeScalars.contains(where: { symbols.contains($0) }) else {
            throw Abort(.badRequest, reason: "Password must contain at least one special character")
        }
    }

    private func responseUsername(for user: User) -> String {
        if let username = user.username?.trimmingCharacters(in: .whitespacesAndNewlines),
            !username.isEmpty {
            return username
        }
        if let prefix = user.email.split(separator: "@").first, !prefix.isEmpty {
            return String(prefix)
        }
        return user.email
    }

    private func responseDateOfBirth(for user: User) -> Date {
        user.dateOfBirth ?? defaultDateOfBirth()
    }

    private func defaultDateOfBirth() -> Date {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let twentyYearsAgoYear = currentYear - 20
        return calendar.date(from: DateComponents(year: twentyYearsAgoYear, month: 1, day: 1))
            ?? Date()
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
