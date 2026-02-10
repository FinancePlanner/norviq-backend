import Vapor
import Foundation

struct AuthRegisterRequest: Content {
    let email: String
    let password: String
}

struct AuthLoginRequest: Content {
    let email: String
    let password: String
}

struct AuthResponse: Content {
    let token: String
    let userId: UUID
    let expiresIn: Int
    let refreshToken: String
    let refreshExpiresIn: Int
}

struct AuthUserResponse: Content {
    let id: String
    let email: String
}

struct AuthForgotPasswordRequest: Content {
    let email: String
}

struct AuthForgotPasswordResponse: Content {
    let message: String
    let resetCode: String?
}

struct AuthResetPasswordRequest: Content {
    let email: String
    let code: String
    let newPassword: String
}

struct AuthRefreshRequest: Content {
    let refreshToken: String
}
