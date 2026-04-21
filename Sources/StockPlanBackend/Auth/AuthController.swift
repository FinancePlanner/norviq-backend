import Foundation
import StockPlanShared
import Vapor

struct AuthController: RouteCollection {
    private static let mfaCapabilityHeader = "X-StockPlan-Client-Capabilities"
    private static let mfaCapabilityToken = "mfa-auth-v1"

    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("auth")

        let registerRateLimit = RateLimitMiddleware(limit: 5, interval: 60, keyPrefix: "ratelimit:register")
        let loginRateLimit = RateLimitMiddleware(limit: 10, interval: 60, keyPrefix: "ratelimit:login")
        let forgotPasswordRateLimit = RateLimitMiddleware(limit: 5, interval: 300, keyPrefix: "ratelimit:forgot-password")
        let resendResetRateLimit = RateLimitMiddleware(limit: 5, interval: 300, keyPrefix: "ratelimit:resend-reset")
        let resetPasswordRateLimit = RateLimitMiddleware(limit: 5, interval: 300, keyPrefix: "ratelimit:reset-password")
        let refreshRateLimit = RateLimitMiddleware(limit: 30, interval: 60, keyPrefix: "ratelimit:refresh")
        let mfaVerifyRateLimit = RateLimitMiddleware(limit: 20, interval: 60, keyPrefix: "ratelimit:mfa-verify")
        let mfaResendRateLimit = RateLimitMiddleware(limit: 10, interval: 60, keyPrefix: "ratelimit:mfa-resend")

        auth.grouped(registerRateLimit).post("register", use: register)
        auth.grouped(loginRateLimit).post("login", use: login)
        auth.grouped(forgotPasswordRateLimit).post("forgot-password", use: forgotPassword)
        auth.grouped(resendResetRateLimit).post("resend-reset", use: resendReset)
        auth.grouped(resetPasswordRateLimit).post("reset-password", use: resetPassword)
        auth.grouped(refreshRateLimit).post("refresh", use: refresh)
        auth.grouped(mfaVerifyRateLimit).post("mfa", "verify", use: mfaVerify)
        auth.grouped(mfaResendRateLimit).post("mfa", "resend", use: mfaResend)
        auth.group("oauth", ":provider") { oauth in
            oauth.post("start", use: oauthStart)
            oauth.post("exchange", use: oauthExchange)
        }

        let protected = auth.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        protected.get("me", use: me)
    }

    @Sendable
    func register(req: Request) async throws -> AuthResponse {
        let payload = try req.content.decode(AuthRegisterRequest.self)
        return try await req.application.authService.register(
            username: payload.username,
            email: payload.email,
            password: payload.password,
            confirmPassword: payload.confirmPassword,
            dateOfBirth: payload.dateOfBirth,
            on: req
        )
    }

    @Sendable
    func login(req: Request) async throws -> Response {
        let payload = try req.content.decode(AuthLoginRequest.self)
        let requiresMFA = try requireMFA(for: req)
        let outcome = try await req.application.authService.login(
            email: payload.email,
            password: payload.password,
            requireMFA: requiresMFA,
            on: req
        )
        return try loginResponse(for: outcome, req: req)
    }

    @Sendable
    func me(req: Request) async throws -> AuthUserResponse {
        try await req.application.authService.currentUser(from: req)
    }

    @Sendable
    func forgotPassword(req: Request) async throws -> AuthForgotPasswordResponse {
        let payload = try req.content.decode(AuthForgotPasswordRequest.self)
        return try await req.application.authService.forgotPassword(email: payload.email, on: req)
    }

    @Sendable
    func resendReset(req: Request) async throws -> AuthForgotPasswordResponse {
        let payload = try req.content.decode(AuthForgotPasswordRequest.self)
        return try await req.application.authService.resendResetCode(email: payload.email, on: req)
    }

    @Sendable
    func resetPassword(req: Request) async throws -> HTTPStatus {
        let payload = try req.content.decode(AuthResetPasswordRequest.self)
        return try await req.application.authService.resetPassword(
            email: payload.email,
            code: payload.code,
            newPassword: payload.newPassword,
            on: req
        )
    }

    @Sendable
    func refresh(req: Request) async throws -> AuthResponse {
        let payload = try req.content.decode(AuthRefreshRequest.self)
        return try await req.application.authService.refresh(using: payload.refreshToken, on: req)
    }

    @Sendable
    func mfaVerify(req: Request) async throws -> AuthResponse {
        let payload = try req.content.decode(AuthMFAVerifyRequest.self)
        return try await req.application.authService.verifyMFA(
            challengeId: payload.challengeId,
            code: payload.code,
            on: req
        )
    }

    @Sendable
    func mfaResend(req: Request) async throws -> Response {
        let payload = try req.content.decode(AuthMFAResendRequest.self)
        let challenge = try await req.application.authService.resendMFA(
            challengeId: payload.challengeId,
            on: req
        )
        return try jsonResponse(challenge)
    }

    @Sendable
    func oauthStart(req: Request) async throws -> OAuthStartResponse {
        let provider = try oauthProvider(from: req)
        let payload = try req.content.decode(OAuthStartRequest.self)
        return try await req.application.authService.oauthStart(
            provider: provider,
            redirectURI: payload.redirectURI,
            on: req
        )
    }

    @Sendable
    func oauthExchange(req: Request) async throws -> Response {
        let provider = try oauthProvider(from: req)
        let payload = try req.content.decode(OAuthExchangeRequest.self)
        let requiresMFA = try requireMFA(for: req)
        let outcome = try await req.application.authService.oauthExchange(
            provider: provider,
            flowId: payload.flowId,
            code: payload.code,
            state: payload.state,
            redirectURI: payload.redirectURI,
            requireMFA: requiresMFA,
            on: req
        )
        return try loginResponse(for: outcome, req: req)
    }

    private func oauthProvider(from req: Request) throws -> OAuthProvider {
        guard let rawProvider = req.parameters.get("provider")?.lowercased(),
            let provider = OAuthProvider(rawValue: rawProvider)
        else {
            throw Abort(.badRequest, reason: "Unsupported OAuth provider")
        }
        return provider
    }

    private func requireMFA(for req: Request) throws -> Bool {
        let config = req.application.authService.mfaConfig
        guard config.enabled else {
            return false
        }

        if clientSupportsMFA(req) {
            return true
        }

        guard config.allowLegacyBypass else {
            throw Abort(.upgradeRequired, reason: "Please update the app to continue signing in.")
        }
        return false
    }

    private func clientSupportsMFA(_ req: Request) -> Bool {
        let raw = req.headers.first(name: Self.mfaCapabilityHeader) ?? ""
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains(Self.mfaCapabilityToken)
    }

    private func loginResponse(for outcome: AuthLoginOutcome, req: Request) throws -> Response {
        if clientSupportsMFA(req) {
            return try jsonResponse(outcome)
        }

        guard let auth = outcome.auth else {
            throw Abort(.badRequest, reason: "MFA is required for this client.")
        }
        return try jsonResponse(auth)
    }

    private func jsonResponse<T: Encodable>(_ payload: T) throws -> Response {
        let data = try JSONEncoder.backendAPI.encode(payload)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }
}
