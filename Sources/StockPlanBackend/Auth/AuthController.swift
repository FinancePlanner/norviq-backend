import Vapor
import Foundation

struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        auth.post("register", use: register)
        auth.post("login", use: login)
        auth.post("forgot-password", use: forgotPassword)
        auth.post("resend-reset", use: resendReset)
        auth.post("reset-password", use: resetPassword)
        auth.post("refresh", use: refresh)

        let protected = auth.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        protected.get("me", use: me)
    }

    @Sendable
    func register(req: Request) async throws -> AuthResponse {
        let payload = try req.content.decode(AuthRegisterRequest.self)
        return try await req.application.authService.register(email: payload.email, password: payload.password, on: req)
    }

    @Sendable
    func login(req: Request) async throws -> AuthResponse {
        let payload = try req.content.decode(AuthLoginRequest.self)
        return try await req.application.authService.login(email: payload.email, password: payload.password, on: req)
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
}
