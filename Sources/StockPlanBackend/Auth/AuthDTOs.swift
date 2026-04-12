import Foundation
import StockPlanShared
import Vapor

struct AuthRegisterRequest: Codable, Sendable, Equatable {
    let username: String
    let password: String
    let confirmPassword: String
    let email: String
    let dateOfBirth: Date

    init(
        username: String,
        password: String,
        confirmPassword: String,
        email: String,
        dateOfBirth: Date
    ) {
        self.username = username
        self.password = password
        self.confirmPassword = confirmPassword
        self.email = email
        self.dateOfBirth = dateOfBirth
    }

    private enum CodingKeys: String, CodingKey {
        case username
        case password
        case confirmPassword
        case confirm_password
        case email
        case dateOfBirth
        case date_of_birth
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decode(String.self, forKey: .username)
        password = try container.decode(String.self, forKey: .password)
        if let confirmPassword = try container.decodeIfPresent(String.self, forKey: .confirmPassword)
            ?? container.decodeIfPresent(String.self, forKey: .confirm_password) {
            self.confirmPassword = confirmPassword
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.confirmPassword,
                .init(codingPath: decoder.codingPath, debugDescription: "Missing confirmPassword")
            )
        }
        email = try container.decode(String.self, forKey: .email)
        if let parsedDateOfBirth = try? SharedDateDecoder.decodeDate(from: container, forKey: .dateOfBirth) {
            dateOfBirth = parsedDateOfBirth
        } else {
            dateOfBirth = try SharedDateDecoder.decodeDate(from: container, forKey: .date_of_birth)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(username, forKey: .username)
        try container.encode(password, forKey: .password)
        try container.encode(confirmPassword, forKey: .confirmPassword)
        try container.encode(email, forKey: .email)
        try container.encode(dateOfBirth, forKey: .dateOfBirth)
    }
}

typealias AuthLoginRequest = StockPlanShared.AuthLoginRequest
typealias AuthResponse = StockPlanShared.AuthResponse
typealias AuthLoginOutcome = StockPlanShared.AuthLoginOutcome
typealias AuthLoginOutcomeStatus = StockPlanShared.AuthLoginOutcomeStatus
typealias AuthMFAChannel = StockPlanShared.AuthMFAChannel
typealias AuthMFAChallengeResponse = StockPlanShared.AuthMFAChallengeResponse
typealias AuthMFAVerifyRequest = StockPlanShared.AuthMFAVerifyRequest
typealias AuthMFAResendRequest = StockPlanShared.AuthMFAResendRequest
typealias AuthRegisterResponse = StockPlanShared.AuthRegisterResponse
typealias AuthUserResponse = StockPlanShared.AuthUserResponse
typealias AuthForgotPasswordRequest = StockPlanShared.AuthForgotPasswordRequest
typealias AuthForgotPasswordResponse = StockPlanShared.AuthForgotPasswordResponse
typealias AuthResetPasswordRequest = StockPlanShared.AuthResetPasswordRequest
typealias AuthRefreshRequest = StockPlanShared.AuthRefreshRequest
typealias OAuthProvider = StockPlanShared.OAuthProvider

extension AuthLoginOutcome: @retroactive Content {}
extension AuthMFAChallengeResponse: @retroactive Content {}
extension AuthMFAVerifyRequest: @retroactive Content {}
extension AuthMFAResendRequest: @retroactive Content {}

struct OAuthStartRequest: Codable, Sendable, Equatable {
    let redirectURI: String

    init(redirectURI: String) {
        self.redirectURI = redirectURI
    }

    private enum CodingKeys: String, CodingKey {
        case redirectURI
        case redirectUri
        case redirect_uri
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let redirectURI = try container.decodeIfPresent(String.self, forKey: .redirectURI)
            ?? container.decodeIfPresent(String.self, forKey: .redirectUri)
            ?? container.decodeIfPresent(String.self, forKey: .redirect_uri) {
            self.redirectURI = redirectURI
            return
        }

        throw DecodingError.keyNotFound(
            CodingKeys.redirectURI,
            .init(codingPath: decoder.codingPath, debugDescription: "Missing redirectURI")
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(redirectURI, forKey: .redirectURI)
    }
}

struct OAuthStartResponse: Codable, Sendable, Equatable {
    let flowId: UUID
    let authorizationURL: String
    let expiresIn: Int

    init(flowId: UUID, authorizationURL: String, expiresIn: Int) {
        self.flowId = flowId
        self.authorizationURL = authorizationURL
        self.expiresIn = expiresIn
    }

    private enum CodingKeys: String, CodingKey {
        case flowId
        case flow_id
        case authorizationURL
        case authorizationUrl
        case authorization_url
        case expiresIn
        case expires_in
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guard let flowId = try container.decodeIfPresent(UUID.self, forKey: .flowId)
            ?? container.decodeIfPresent(UUID.self, forKey: .flow_id) else {
            throw DecodingError.keyNotFound(
                CodingKeys.flowId,
                .init(codingPath: decoder.codingPath, debugDescription: "Missing flowId")
            )
        }

        guard let authorizationURL = try container.decodeIfPresent(String.self, forKey: .authorizationURL)
            ?? container.decodeIfPresent(String.self, forKey: .authorizationUrl)
            ?? container.decodeIfPresent(String.self, forKey: .authorization_url) else {
            throw DecodingError.keyNotFound(
                CodingKeys.authorizationURL,
                .init(codingPath: decoder.codingPath, debugDescription: "Missing authorizationURL")
            )
        }

        guard let expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn)
            ?? container.decodeIfPresent(Int.self, forKey: .expires_in) else {
            throw DecodingError.keyNotFound(
                CodingKeys.expiresIn,
                .init(codingPath: decoder.codingPath, debugDescription: "Missing expiresIn")
            )
        }

        self.flowId = flowId
        self.authorizationURL = authorizationURL
        self.expiresIn = expiresIn
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(flowId, forKey: .flowId)
        try container.encode(authorizationURL, forKey: .authorizationURL)
        try container.encode(expiresIn, forKey: .expiresIn)
    }
}

struct OAuthExchangeRequest: Codable, Sendable, Equatable {
    let flowId: UUID
    let code: String
    let state: String
    let redirectURI: String

    init(flowId: UUID, code: String, state: String, redirectURI: String) {
        self.flowId = flowId
        self.code = code
        self.state = state
        self.redirectURI = redirectURI
    }

    private enum CodingKeys: String, CodingKey {
        case flowId
        case flow_id
        case code
        case state
        case redirectURI
        case redirectUri
        case redirect_uri
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guard let flowId = try container.decodeIfPresent(UUID.self, forKey: .flowId)
            ?? container.decodeIfPresent(UUID.self, forKey: .flow_id) else {
            throw DecodingError.keyNotFound(
                CodingKeys.flowId,
                .init(codingPath: decoder.codingPath, debugDescription: "Missing flowId")
            )
        }

        guard let redirectURI = try container.decodeIfPresent(String.self, forKey: .redirectURI)
            ?? container.decodeIfPresent(String.self, forKey: .redirectUri)
            ?? container.decodeIfPresent(String.self, forKey: .redirect_uri) else {
            throw DecodingError.keyNotFound(
                CodingKeys.redirectURI,
                .init(codingPath: decoder.codingPath, debugDescription: "Missing redirectURI")
            )
        }

        self.flowId = flowId
        self.code = try container.decode(String.self, forKey: .code)
        self.state = try container.decode(String.self, forKey: .state)
        self.redirectURI = redirectURI
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(flowId, forKey: .flowId)
        try container.encode(code, forKey: .code)
        try container.encode(state, forKey: .state)
        try container.encode(redirectURI, forKey: .redirectURI)
    }
}
