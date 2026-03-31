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

extension AuthRegisterRequest: Content {}
extension AuthLoginRequest: Content {}
extension AuthResponse: Content {}
extension AuthUserResponse: Content {}
extension AuthForgotPasswordRequest: Content {}
extension AuthForgotPasswordResponse: Content {}
extension AuthResetPasswordRequest: Content {}
extension AuthRefreshRequest: Content {}
