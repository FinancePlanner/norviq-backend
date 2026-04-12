@testable import StockPlanBackend
import VaporTesting
import Testing
import Fluent
import Foundation
import Crypto

@Suite("Auth Tests", .serialized)
struct AuthTests {
    private func withApp(_ test: (Application) async throws -> ()) async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func makeRegisterRequest(
        email: String,
        password: String = "Password123!",
        username: String = "valid_user",
        dateOfBirth: Date = Date(timeIntervalSince1970: 946_684_800)
    ) -> AuthRegisterRequest {
        AuthRegisterRequest(
            username: username,
            password: password,
            confirmPassword: password,
            email: email,
            dateOfBirth: dateOfBirth
        )
    }

    private func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    @Test("Registration fails when password confirmation does not match")
    func registerPasswordConfirmationMismatch() async throws {
        try await withApp { app in
            let registerReq = AuthRegisterRequest(
                username: "mismatch_user",
                password: "Password123!",
                confirmPassword: "Password123",
                email: "mismatch@example.com",
                dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
            )

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    // MARK: - Registration Tests

    @Test("Successful user registration")
    func registerSuccess() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "newuser@example.com", password: "Password123!")
            
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(AuthResponse.self)
                #expect(!response.token.isEmpty)
                #expect(response.expiresIn > 0)
                #expect(!response.refreshToken.isEmpty)
                #expect(response.refreshExpiresIn > 0)
            })
        }
    }

    @Test("Registration persists encrypted date of birth")
    func registerStoresEncryptedDateOfBirth() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "encrypted-dob@example.com")
            var userID: UUID?

            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                userID = try res.content.decode(AuthResponse.self).userId
            })

            guard let userID,
                  let user = try await User.find(userID, on: app.db)
            else {
                Issue.record("Expected created user")
                return
            }

            #expect(user.dateOfBirthEncrypted != nil)
        }
    }

    @Test("Registration fails with duplicate email")
    func registerDuplicateEmail() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "duplicate@example.com", password: "Password123!")
            
            // First registration should succeed
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            
            // Second registration with same email should fail
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })
        }
    }

    @Test("Registration fails with invalid email")
    func registerInvalidEmail() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "invalid-email", password: "Password123!")
            
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Registration fails with short password")
    func registerShortPassword() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "test@example.com", password: "short")
            
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Email normalization - trims whitespace and lowercases")
    func registerEmailNormalization() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "  TEST@Example.COM  ", password: "Password123!")
            
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            
            // Now try to login with normalized email
            let loginReq = AuthLoginRequest(email: "test@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(loginReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    // MARK: - Login Tests

    @Test("Successful login")
    func loginSuccess() async throws {
        try await withApp { app in
            let credentials = makeRegisterRequest(email: "login@example.com", password: "Password123!")
            
            // Register first
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(credentials)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            
            // Then login
            let loginReq = AuthLoginRequest(email: "login@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(loginReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(AuthResponse.self)
                #expect(!response.token.isEmpty)
                #expect(!response.refreshToken.isEmpty)
            })
        }
    }

    @Test("Login fails with wrong password")
    func loginWrongPassword() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "wrongpwd@example.com", password: "Password123!")
            
            // Register first
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            
            // Login with wrong password
            let loginReq = AuthLoginRequest(email: "wrongpwd@example.com", password: "WrongPassword1!")
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(loginReq)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Login fails with non-existent email")
    func loginNonExistentEmail() async throws {
        try await withApp { app in
            let loginReq = AuthLoginRequest(email: "nonexistent@example.com", password: "Password123!")
            
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(loginReq)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Login returns MFA challenge for MFA-capable clients")
    func loginReturnsMFAChallengeForCapableClient() async throws {
        setenv("AUTH_MFA_ENABLED", "true", 1)
        defer { unsetenv("AUTH_MFA_ENABLED") }

        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "mfa-login@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            let loginReq = AuthLoginRequest(email: "mfa-login@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-StockPlan-Client-Capabilities", value: "mfa-auth-v1")
                try req.content.encode(loginReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let outcome = try res.content.decode(AuthLoginOutcome.self)
                #expect(outcome.status == .mfaRequired)
                #expect(outcome.mfa != nil)
                #expect(outcome.auth == nil)
            })
        }
    }

    @Test("MFA verify issues tokens for valid challenge")
    func mfaVerifyIssuesTokens() async throws {
        setenv("AUTH_MFA_ENABLED", "true", 1)
        defer { unsetenv("AUTH_MFA_ENABLED") }

        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "mfa-verify@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            var challengeID: UUID?
            let loginReq = AuthLoginRequest(email: "mfa-verify@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-StockPlan-Client-Capabilities", value: "mfa-auth-v1")
                try req.content.encode(loginReq)
            }, afterResponse: { res async throws in
                let outcome = try res.content.decode(AuthLoginOutcome.self)
                challengeID = outcome.mfa?.challengeId
            })

            guard let challengeID,
                  let challenge = try await MFAChallenge.find(challengeID, on: app.db) else {
                Issue.record("Expected MFA challenge to exist")
                return
            }

            challenge.codeHash = sha256("123456")
            try await challenge.save(on: app.db)

            try await app.testing().test(.POST, "v1/auth/mfa/verify", beforeRequest: { req in
                try req.content.encode(AuthMFAVerifyRequest(challengeId: challengeID, code: "123456"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let auth = try res.content.decode(AuthResponse.self)
                #expect(!auth.token.isEmpty)
                #expect(!auth.refreshToken.isEmpty)
            })
        }
    }

    @Test("Non-capable client is rejected when legacy bypass is disabled")
    func loginRejectsLegacyWhenBypassDisabled() async throws {
        setenv("AUTH_MFA_ENABLED", "true", 1)
        setenv("AUTH_MFA_ALLOW_LEGACY_BYPASS", "false", 1)
        defer {
            unsetenv("AUTH_MFA_ENABLED")
            unsetenv("AUTH_MFA_ALLOW_LEGACY_BYPASS")
        }

        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "legacy-bypass@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            let loginReq = AuthLoginRequest(email: "legacy-bypass@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(loginReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .upgradeRequired)
            })
        }
    }

    // MARK: - Current User Tests

    @Test("Get current user with valid token")
    func getCurrentUser() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "currentuser@example.com", password: "Password123!")
            var authToken: String = ""
            
            // Register to get a token
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(AuthResponse.self)
                authToken = response.token
            })
            
            // Get current user
            try await app.testing().test(.GET, "v1/auth/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: authToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let user = try res.content.decode(AuthUserResponse.self)
                #expect(user.email == "currentuser@example.com")
            })
        }
    }

    @Test("Get current user fails without token")
    func getCurrentUserNoToken() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/auth/me", afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    // MARK: - Refresh Token Tests

    @Test("Successful token refresh")
    func refreshTokenSuccess() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "refresh@example.com", password: "Password123!")
            var refreshToken: String = ""
            
            // Register to get refresh token
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(AuthResponse.self)
                refreshToken = response.refreshToken
            })
            
            // Use refresh token to get new tokens
            let refreshReq = AuthRefreshRequest(refreshToken: refreshToken)
            try await app.testing().test(.POST, "v1/auth/refresh", beforeRequest: { req in
                try req.content.encode(refreshReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(AuthResponse.self)
                #expect(!response.token.isEmpty)
                #expect(!response.refreshToken.isEmpty)
                // New refresh token should be different (old one is revoked)
                #expect(response.refreshToken != refreshToken)
            })
        }
    }

    @Test("Refresh token fails with invalid token")
    func refreshTokenInvalid() async throws {
        try await withApp { app in
            let refreshReq = AuthRefreshRequest(refreshToken: "invalid-refresh-token")
            
            try await app.testing().test(.POST, "v1/auth/refresh", beforeRequest: { req in
                try req.content.encode(refreshReq)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Refresh token fails after being used (rotation)")
    func refreshTokenRotation() async throws {
        try await withApp { app in
            let registerReq = makeRegisterRequest(email: "rotation@example.com", password: "Password123!")
            var refreshToken: String = ""
            
            // Register to get refresh token
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async throws in
                let response = try res.content.decode(AuthResponse.self)
                refreshToken = response.refreshToken
            })
            
            // First refresh should succeed
            let refreshReq = AuthRefreshRequest(refreshToken: refreshToken)
            try await app.testing().test(.POST, "v1/auth/refresh", beforeRequest: { req in
                try req.content.encode(refreshReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            
            // Second refresh with same token should fail (token was revoked)
            try await app.testing().test(.POST, "v1/auth/refresh", beforeRequest: { req in
                try req.content.encode(refreshReq)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    // MARK: - OAuth Tests

    @Test("OAuth start succeeds for configured Google provider")
    func oauthStartGoogleSuccess() async throws {
        setenv("OAUTH_GOOGLE_CLIENT_ID", "google-client-id", 1)
        setenv("OAUTH_GOOGLE_CLIENT_SECRET", "google-client-secret", 1)
        setenv("OAUTH_ALLOWED_REDIRECT_URIS", "norviqa://oauth/callback", 1)
        defer {
            unsetenv("OAUTH_GOOGLE_CLIENT_ID")
            unsetenv("OAUTH_GOOGLE_CLIENT_SECRET")
            unsetenv("OAUTH_ALLOWED_REDIRECT_URIS")
        }

        try await withApp { app in
            let startReq = OAuthStartRequest(redirectURI: "norviqa://oauth/callback")
            try await app.testing().test(.POST, "v1/auth/oauth/google/start", beforeRequest: { req in
                try req.content.encode(startReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(OAuthStartResponse.self)
                #expect(response.expiresIn > 0)
                #expect(!response.authorizationURL.isEmpty)
                #expect(response.authorizationURL.contains("accounts.google.com"))
            })
        }
    }

    @Test("OAuth start fails for unsupported provider")
    func oauthStartUnsupportedProvider() async throws {
        try await withApp { app in
            let startReq = OAuthStartRequest(redirectURI: "norviqa://oauth/callback")
            try await app.testing().test(.POST, "v1/auth/oauth/unknown/start", beforeRequest: { req in
                try req.content.encode(startReq)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    // MARK: - Password Reset Tests

    @Test("Forgot password returns success message")
    func forgotPasswordSuccess() async throws {
        try await withApp { app in
            // Register a user first
            let registerReq = makeRegisterRequest(email: "forgot@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            
            // Request password reset
            let forgotReq = AuthForgotPasswordRequest(email: "forgot@example.com")
            try await app.testing().test(.POST, "v1/auth/forgot-password", beforeRequest: { req in
                try req.content.encode(forgotReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(AuthForgotPasswordResponse.self)
                #expect(response.message.contains("reset code"))
            })
        }
    }

    @Test("Forgot password for non-existent email still returns success")
    func forgotPasswordNonExistent() async throws {
        try await withApp { app in
            let forgotReq = AuthForgotPasswordRequest(email: "nonexistent@example.com")
            
            try await app.testing().test(.POST, "v1/auth/forgot-password", beforeRequest: { req in
                try req.content.encode(forgotReq)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(AuthForgotPasswordResponse.self)
                // Should still return success message to prevent email enumeration
                #expect(response.message.contains("reset code"))
            })
        }
    }

    @Test("Reset password fails with invalid code")
    func resetPasswordInvalidCode() async throws {
        try await withApp { app in
            // Register a user first
            let registerReq = makeRegisterRequest(email: "resetinvalid@example.com", password: "Password123!")
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(registerReq)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            
            // Try to reset with invalid code
            let resetReq = AuthResetPasswordRequest(
                email: "resetinvalid@example.com",
                code: "000000",
                newPassword: "NewPassword123!"
            )
            try await app.testing().test(.POST, "v1/auth/reset-password", beforeRequest: { req in
                try req.content.encode(resetReq)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }
}

// MARK: - AuthRepository Unit Tests

@Suite("AuthRepository Tests", .serialized)
struct AuthRepositoryTests {
    private func withApp(_ test: (Application) async throws -> ()) async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    @Test("Create and find user by email")
    func createAndFindUserByEmail() async throws {
        try await withApp { app in
            let repo = DatabaseAuthRepository()
            
            // Create a user
            let user = try await repo.createUser(
                email: "repo@example.com",
                passwordHash: "hashed_password",
                on: app.db
            )
            
            #expect(user.id != nil)
            #expect(user.email == "repo@example.com")
            
            // Find by email
            let found = try await repo.findUser(email: "repo@example.com", on: app.db)
            #expect(found != nil)
            #expect(found?.id == user.id)
        }
    }

    @Test("Find user by ID")
    func findUserById() async throws {
        try await withApp { app in
            let repo = DatabaseAuthRepository()
            
            let user = try await repo.createUser(
                email: "findbyid@example.com",
                passwordHash: "hashed_password",
                on: app.db
            )
            
            let userId = try #require(user.id)
            let found = try await repo.findUser(id: userId, on: app.db)
            
            #expect(found != nil)
            #expect(found?.email == "findbyid@example.com")
        }
    }

    @Test("Find user returns nil for non-existent email")
    func findUserNonExistent() async throws {
        try await withApp { app in
            let repo = DatabaseAuthRepository()
            
            let found = try await repo.findUser(email: "nonexistent@example.com", on: app.db)
            #expect(found == nil)
        }
    }

    @Test("Create and find valid password reset token")
    func passwordResetTokenLifecycle() async throws {
        try await withApp { app in
            let repo = DatabaseAuthRepository()
            
            // Create a user first
            let user = try await repo.createUser(
                email: "resettoken@example.com",
                passwordHash: "hashed_password",
                on: app.db
            )
            let userId = try #require(user.id)
            
            // Create a reset token
            let codeHash = "test_code_hash"
            let expiresAt = Date().addingTimeInterval(15 * 60) // 15 minutes
            try await repo.createPasswordResetToken(
                userId: userId,
                codeHash: codeHash,
                expiresAt: expiresAt,
                on: app.db
            )
            
            // Find the valid token
            let token = try await repo.findValidPasswordResetToken(
                userId: userId,
                codeHash: codeHash,
                now: Date(),
                on: app.db
            )
            
            #expect(token != nil)
            #expect(token?.userId == userId)
            #expect(token?.codeHash == codeHash)
        }
    }

    @Test("Expired password reset token not found")
    func expiredPasswordResetToken() async throws {
        try await withApp { app in
            let repo = DatabaseAuthRepository()
            
            let user = try await repo.createUser(
                email: "expired@example.com",
                passwordHash: "hashed_password",
                on: app.db
            )
            let userId = try #require(user.id)
            
            // Create an expired token
            let codeHash = "expired_code_hash"
            let expiresAt = Date().addingTimeInterval(-60) // Already expired
            try await repo.createPasswordResetToken(
                userId: userId,
                codeHash: codeHash,
                expiresAt: expiresAt,
                on: app.db
            )
            
            // Try to find - should return nil
            let token = try await repo.findValidPasswordResetToken(
                userId: userId,
                codeHash: codeHash,
                now: Date(),
                on: app.db
            )
            
            #expect(token == nil)
        }
    }

    @Test("Mark password reset token as used")
    func markPasswordResetTokenUsed() async throws {
        try await withApp { app in
            let repo = DatabaseAuthRepository()
            
            let user = try await repo.createUser(
                email: "markused@example.com",
                passwordHash: "hashed_password",
                on: app.db
            )
            let userId = try #require(user.id)
            
            let codeHash = "used_code_hash"
            let expiresAt = Date().addingTimeInterval(15 * 60)
            try await repo.createPasswordResetToken(
                userId: userId,
                codeHash: codeHash,
                expiresAt: expiresAt,
                on: app.db
            )
            
            // Find and mark as used
            let token = try await repo.findValidPasswordResetToken(
                userId: userId,
                codeHash: codeHash,
                now: Date(),
                on: app.db
            )
            let foundToken = try #require(token)
            
            try await repo.markPasswordResetTokenUsed(foundToken, usedAt: Date(), on: app.db)
            
            // Should not be findable anymore
            let usedToken = try await repo.findValidPasswordResetToken(
                userId: userId,
                codeHash: codeHash,
                now: Date(),
                on: app.db
            )
            
            #expect(usedToken == nil)
        }
    }

    @Test("Create and find valid refresh token")
    func refreshTokenLifecycle() async throws {
        try await withApp { app in
            let repo = DatabaseAuthRepository()
            
            let user = try await repo.createUser(
                email: "refreshrepo@example.com",
                passwordHash: "hashed_password",
                on: app.db
            )
            let userId = try #require(user.id)
            
            // Create refresh token
            let tokenHash = "refresh_token_hash"
            let expiresAt = Date().addingTimeInterval(30 * 24 * 60 * 60) // 30 days
            try await repo.createRefreshToken(
                userId: userId,
                tokenHash: tokenHash,
                expiresAt: expiresAt,
                on: app.db
            )
            
            // Find the valid token
            let token = try await repo.findValidRefreshToken(
                tokenHash: tokenHash,
                now: Date(),
                on: app.db
            )
            
            #expect(token != nil)
            #expect(token?.userId == userId)
            #expect(token?.tokenHash == tokenHash)
        }
    }

    @Test("Expired refresh token not found")
    func expiredRefreshToken() async throws {
        try await withApp { app in
            let repo = DatabaseAuthRepository()
            
            let user = try await repo.createUser(
                email: "expiredrefresh@example.com",
                passwordHash: "hashed_password",
                on: app.db
            )
            let userId = try #require(user.id)
            
            // Create an expired token
            let tokenHash = "expired_refresh_hash"
            let expiresAt = Date().addingTimeInterval(-60) // Already expired
            try await repo.createRefreshToken(
                userId: userId,
                tokenHash: tokenHash,
                expiresAt: expiresAt,
                on: app.db
            )
            
            // Try to find - should return nil
            let token = try await repo.findValidRefreshToken(
                tokenHash: tokenHash,
                now: Date(),
                on: app.db
            )
            
            #expect(token == nil)
        }
    }

    @Test("Revoke refresh token")
    func revokeRefreshToken() async throws {
        try await withApp { app in
            let repo = DatabaseAuthRepository()
            
            let user = try await repo.createUser(
                email: "revokerefresh@example.com",
                passwordHash: "hashed_password",
                on: app.db
            )
            let userId = try #require(user.id)
            
            let tokenHash = "revoke_token_hash"
            let expiresAt = Date().addingTimeInterval(30 * 24 * 60 * 60)
            try await repo.createRefreshToken(
                userId: userId,
                tokenHash: tokenHash,
                expiresAt: expiresAt,
                on: app.db
            )
            
            // Find and revoke
            let token = try await repo.findValidRefreshToken(
                tokenHash: tokenHash,
                now: Date(),
                on: app.db
            )
            let foundToken = try #require(token)
            
            try await repo.revokeRefreshToken(foundToken, revokedAt: Date(), on: app.db)
            
            // Should not be findable anymore
            let revokedToken = try await repo.findValidRefreshToken(
                tokenHash: tokenHash,
                now: Date(),
                on: app.db
            )
            
            #expect(revokedToken == nil)
        }
    }
}
