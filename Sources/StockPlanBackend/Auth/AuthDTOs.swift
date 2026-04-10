import Foundation
import StockPlanShared
import Vapor

typealias AuthRegisterRequest = StockPlanShared.AuthRegisterRequest
typealias AuthLoginRequest = StockPlanShared.AuthLoginRequest
typealias AuthResponse = StockPlanShared.AuthResponse
typealias AuthRegisterResponse = StockPlanShared.AuthRegisterResponse
typealias AuthUserResponse = StockPlanShared.AuthUserResponse
typealias AuthForgotPasswordRequest = StockPlanShared.AuthForgotPasswordRequest
typealias AuthForgotPasswordResponse = StockPlanShared.AuthForgotPasswordResponse
typealias AuthResetPasswordRequest = StockPlanShared.AuthResetPasswordRequest
typealias AuthRefreshRequest = StockPlanShared.AuthRefreshRequest
typealias OAuthProvider = StockPlanShared.OAuthProvider

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
