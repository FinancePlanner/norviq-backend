import Foundation
import Vapor

struct AuthRegisterRequest: Content, Equatable {
    let username: String
    let password: String
    let email: String
    let firstName: String
    let lastName: String
    let dateOfBirth: Date
}

struct AuthLoginRequest: Content, Equatable {
    let email: String
    let password: String
}

struct AuthResponse: Content, Equatable {
    let token: String
    let userId: UUID
    let expiresIn: Int
    let refreshToken: String
    let refreshExpiresIn: Int
    let username: String
    let email: String
    let firstName: String
    let lastName: String
    let dateOfBirth: Date
}

typealias AuthRegisterResponse = AuthResponse

struct AuthUserResponse: Content, Equatable {
    let id: String
    let username: String
    let email: String
    let firstName: String
    let lastName: String
    let dateOfBirth: Date
}

struct AuthForgotPasswordRequest: Content, Equatable {
    let email: String
}

struct AuthForgotPasswordResponse: Content, Equatable {
    let message: String
    let resetCode: String?
}

struct AuthResetPasswordRequest: Content, Equatable {
    let email: String
    let code: String
    let newPassword: String
}

struct AuthRefreshRequest: Content, Equatable {
    let refreshToken: String
}
