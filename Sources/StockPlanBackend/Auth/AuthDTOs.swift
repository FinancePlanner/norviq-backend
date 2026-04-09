import Foundation
import Vapor
import StockPlanShared

typealias AuthRegisterRequest = StockPlanShared.AuthRegisterRequest
typealias AuthLoginRequest = StockPlanShared.AuthLoginRequest
typealias AuthResponse = StockPlanShared.AuthResponse
typealias AuthRegisterResponse = StockPlanShared.AuthRegisterResponse
typealias AuthUserResponse = StockPlanShared.AuthUserResponse
typealias AuthForgotPasswordRequest = StockPlanShared.AuthForgotPasswordRequest
typealias AuthForgotPasswordResponse = StockPlanShared.AuthForgotPasswordResponse
typealias AuthResetPasswordRequest = StockPlanShared.AuthResetPasswordRequest
typealias AuthRefreshRequest = StockPlanShared.AuthRefreshRequest

enum OAuthProvider: String, Codable, Sendable {
    case apple
    case google
    case x
}

struct OAuthStartRequest: Content, Codable, Sendable {
    let redirectURI: String
}

struct OAuthStartResponse: Content, Codable, Sendable {
    let flowId: UUID
    let authorizationURL: String
    let expiresIn: Int
}

struct OAuthExchangeRequest: Content, Codable, Sendable {
    let flowId: UUID
    let code: String
    let state: String
    let redirectURI: String
}
