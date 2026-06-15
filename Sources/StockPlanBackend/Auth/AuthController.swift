import Foundation
import StockPlanShared
import Vapor

struct AuthController: RouteCollection {
    private static let mfaCapabilityHeader = "X-StockPlan-Client-Capabilities"
    private static let mfaCapabilityToken = "mfa-auth-v1"
    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("auth")

        if environment == .testing {
            // Skip rate limiting in tests to avoid 429s during rapid user creation
            auth.post("register", use: register)
            auth.post("login", use: login)
            auth.post("forgot-password", use: forgotPassword)
            auth.post("resend-reset", use: resendReset)
            auth.post("reset-password", use: resetPassword)
            auth.post("refresh", use: refresh)
            auth.post("mfa", "verify", use: mfaVerify)
            auth.post("mfa", "resend", use: mfaResend)
            auth.group("webauthn", "login") { webauthn in
                webauthn.post("options", use: webAuthnLoginOptions)
                webauthn.post("verify", use: webAuthnLoginVerify)
            }
        } else {
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
        }
        auth.group("oauth", ":provider") { oauth in
            oauth.post("start", use: oauthStart)
            oauth.post("exchange", use: oauthExchange)
            oauth.get("callback", use: oauthCallbackBridge)
            oauth.post("callback", use: oauthCallbackBridgePost)
        }
        auth.group("brokers", "ibkr") { brokers in
            brokers.get("callback", use: brokerIBKRCallback)
        }

        let webAuthnLoginRateLimit = RateLimitMiddleware(limit: 20, interval: 60, keyPrefix: "ratelimit:webauthn-login")
        auth.group("webauthn", "login") { webauthn in
            webauthn.grouped(webAuthnLoginRateLimit).post("options", use: webAuthnLoginOptions)
            webauthn.grouped(webAuthnLoginRateLimit).post("verify", use: webAuthnLoginVerify)
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
            trialDays: payload.trialDays,
            couponCode: payload.couponCode,
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
        let outcome = try await req.application.authService.oauthExchange(
            provider: provider,
            flowId: payload.flowId,
            code: payload.code,
            state: payload.state,
            redirectURI: payload.redirectURI,
            on: req
        )
        return try loginResponse(for: outcome, req: req)
    }

    /// HTTPS bridge for OAuth providers that disallow custom-scheme redirect URIs
    /// (e.g. X requires HTTPS, Apple Services IDs prefer HTTPS).
    ///
    /// Returns HTTP 200 HTML with an inline JS redirect so that:
    ///   - X's portal CRC validation (which probes the URL and rejects non-200)
    ///     accepts it.
    ///   - Real callbacks (`?code=...&state=...`) trigger a client-side navigation
    ///     to `norviqa://oauth/callback?<query>`, which ASWebAuthenticationSession
    ///     on iOS (callbackURLScheme="norviqa") intercepts.
    @Sendable
    func oauthCallbackBridge(req _: Request) async throws -> Response {
        let appScheme = Self.oauthCallbackScheme()

        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>OAuth callback</title></head>
        <body>
        <script>
        (function () {
          var search = window.location.search || "";
          if (search.length > 0) {
            window.location.replace("\(appScheme)://oauth/callback" + search);
          }
        })();
        </script>
        </body></html>
        """

        return Self.htmlBridgeResponse(html: html)
    }

    /// POST variant of the callback bridge for Apple Sign-In.
    ///
    /// Apple requires `response_mode=form_post` whenever the requested scope
    /// includes `name` or `email`, so Apple POSTs the OAuth result as
    /// `application/x-www-form-urlencoded` to the configured redirect URI.
    /// We translate that POST body into a query string and bounce it to the
    /// custom scheme via an inline JS redirect, so ASWebAuthenticationSession
    /// can intercept it the same way it does for the GET bridge.
    @Sendable
    func oauthCallbackBridgePost(req: Request) async throws -> Response {
        let payload = try req.content.decode(AppleFormPostCallback.self)
        let appScheme = Self.oauthCallbackScheme()

        var components = URLComponents()
        var items: [URLQueryItem] = []
        if let code = payload.code?.trimmedNonEmpty {
            items.append(URLQueryItem(name: "code", value: code))
        }
        if let state = payload.state?.trimmedNonEmpty {
            items.append(URLQueryItem(name: "state", value: state))
        }
        if let user = payload.user?.trimmedNonEmpty {
            items.append(URLQueryItem(name: "user", value: user))
        }
        if let error = payload.error?.trimmedNonEmpty {
            items.append(URLQueryItem(name: "error", value: error))
        }
        components.queryItems = items.isEmpty ? nil : items
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""

        let escapedRedirect = "\(appScheme)://oauth/callback\(query)"
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>OAuth callback</title></head>
        <body>
        <script>
        window.location.replace("\(escapedRedirect)");
        </script>
        </body></html>
        """

        return Self.htmlBridgeResponse(html: html)
    }

    private static func oauthCallbackScheme() -> String {
        (Environment.get("OAUTH_APP_CALLBACK_SCHEME")?
            .trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? "norviqa"
    }

    private static func htmlBridgeResponse(html: String) -> Response {
        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        response.body = .init(string: html)
        return response
    }

    @Sendable
    func webAuthnLoginOptions(req: Request) async throws -> WebAuthnPublicKeyOptionsResponse {
        try await req.application.webAuthnService.beginLogin(on: req)
    }

    @Sendable
    func webAuthnLoginVerify(req: Request) async throws -> AuthResponse {
        try await req.application.webAuthnService.finishLogin(on: req)
    }

    @Sendable
    func brokerIBKRCallback(req: Request) async throws -> Response {
        guard let flowIdRaw = req.query[String.self, at: "flowId"],
              let flowId = UUID(uuidString: flowIdRaw)
        else {
            throw Abort(.badRequest, reason: "Invalid broker flow id.")
        }
        guard let state = req.query[String.self, at: "state"],
              !state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw Abort(.badRequest, reason: "Missing broker flow state.")
        }
        return try await req.application.brokersService.handleIBKRCallback(flowId: flowId, state: state, on: req)
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

    private func jsonResponse(_ payload: some Encodable) throws -> Response {
        let data = try JSONEncoder.backendAPI.encode(payload)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }
}

private struct AppleFormPostCallback: Content {
    var code: String?
    var state: String?
    var user: String?
    var error: String?
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
