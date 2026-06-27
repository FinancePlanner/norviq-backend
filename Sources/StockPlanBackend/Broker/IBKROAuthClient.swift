import Foundation
import JWT
import JWTKit
import Vapor

enum IBKRConnectMode: Equatable {
    case gateway
    case oauth2

    static func fromEnvironment(hasOAuthConfiguration: Bool) throws -> Self {
        let raw = Environment.get("IBKR_CONNECT_MODE")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch raw {
        case nil, "":
            return hasOAuthConfiguration ? .oauth2 : .gateway
        case "gateway", "client_portal", "client-portal":
            return .gateway
        case "oauth2", "oauth", "web_api", "web-api":
            return .oauth2
        case "auto":
            return hasOAuthConfiguration ? .oauth2 : .gateway
        default:
            throw Abort(.internalServerError, reason: "Unsupported IBKR_CONNECT_MODE.")
        }
    }
}

struct IBKROAuthConfiguration {
    let clientID: String
    let keyID: String?
    let privateKeyPEM: String?
    let authorizationURL: URL
    let tokenURL: URI
    let apiBaseURL: String
    let scope: String?

    static func fromEnvironment() throws -> Self? {
        guard let clientID = Environment.get("IBKR_OAUTH_CLIENT_ID")?.trimmedNonEmpty,
              let authorizationURLRaw = Environment.get("IBKR_OAUTH_AUTHORIZATION_URL")?.trimmedNonEmpty,
              let authorizationURL = URL(string: authorizationURLRaw),
              let tokenURLRaw = Environment.get("IBKR_OAUTH_TOKEN_URL")?.trimmedNonEmpty,
              let apiBaseURL = Environment.get("IBKR_OAUTH_API_BASE_URL")?.trimmedNonEmpty
        else {
            return nil
        }

        return Self(
            clientID: clientID,
            keyID: Environment.get("IBKR_OAUTH_KEY_ID")?.trimmedNonEmpty,
            privateKeyPEM: Environment.get("IBKR_OAUTH_PRIVATE_KEY_PEM")?
                .replacingOccurrences(of: "\\n", with: "\n")
                .trimmedNonEmpty,
            authorizationURL: authorizationURL,
            tokenURL: URI(string: tokenURLRaw),
            apiBaseURL: apiBaseURL,
            scope: Environment.get("IBKR_OAUTH_SCOPE")?.trimmedNonEmpty
        )
    }
}

struct IBKROAuthClient {
    let config: IBKROAuthConfiguration

    func makeAuthorizationURL(state: String, redirectURI: String) throws -> URL {
        guard var components = URLComponents(url: config.authorizationURL, resolvingAgainstBaseURL: false) else {
            throw Abort(.internalServerError, reason: "Failed to create IBKR authorization URL.")
        }

        var queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
        ]
        if let scope = config.scope {
            queryItems.append(URLQueryItem(name: "scope", value: scope))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw Abort(.internalServerError, reason: "Failed to build IBKR authorization URL.")
        }
        return url
    }

    func exchangeCode(code: String, redirectURI: String, on req: Request) async throws -> IBKROAuthTokenResponse {
        let payload = try await tokenRequestPayload(
            grantType: "authorization_code",
            extraFields: [
                "code": code,
                "redirect_uri": redirectURI,
            ]
        )
        return try await sendTokenRequest(payload: payload, on: req)
    }

    func refresh(refreshToken: String, on req: Request) async throws -> IBKROAuthTokenResponse {
        let payload = try await tokenRequestPayload(
            grantType: "refresh_token",
            extraFields: ["refresh_token": refreshToken]
        )
        return try await sendTokenRequest(payload: payload, on: req)
    }

    private func tokenRequestPayload(grantType: String, extraFields: [String: String]) async throws -> String {
        var fields: [String: String] = [
            "client_id": config.clientID,
            "grant_type": grantType,
        ]
        for (key, value) in extraFields {
            fields[key] = value
        }
        fields["client_assertion_type"] = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
        fields["client_assertion"] = try await makeClientAssertion()
        return try ibkrOAuthURLFormEncoded(fields)
    }

    private func sendTokenRequest(payload: String, on req: Request) async throws -> IBKROAuthTokenResponse {
        let tokenResponse = try await req.client.post(config.tokenURL) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .contentType, value: "application/x-www-form-urlencoded")
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            clientRequest.body = .init(string: payload)
        }

        let rawBody = ibkrOAuthExtractBody(from: tokenResponse)
        guard tokenResponse.status == .ok else {
            req.logger.warning("IBKR token request failed status=\(tokenResponse.status.code) body=\(rawBody)")
            throw Abort(.badGateway, reason: "IBKR token request failed with status \(tokenResponse.status.code).")
        }

        do {
            return try tokenResponse.content.decode(IBKROAuthTokenResponse.self)
        } catch {
            req.logger.warning("IBKR token response decode failed body=\(rawBody)")
            throw Abort(.badGateway, reason: "IBKR token response format was not recognized.")
        }
    }

    private func makeClientAssertion() async throws -> String {
        guard let privateKeyPEM = config.privateKeyPEM else {
            throw Abort(.serviceUnavailable, reason: "IBKR OAuth private key is not configured.")
        }

        let keys = JWTKeyCollection()
        do {
            let key = try Insecure.RSA.PrivateKey(pem: privateKeyPEM)
            await keys.add(rsa: key, digestAlgorithm: .sha256, kid: config.keyID.map(JWKIdentifier.init(string:)))
        } catch {
            throw Abort(.internalServerError, reason: "Invalid IBKR OAuth private key format.")
        }

        var header = JWTHeader()
        header.typ = "JWT"
        header.alg = "RS256"
        header.kid = config.keyID

        let now = Date()
        let claims = IBKRClientAssertionClaims(
            iss: IssuerClaim(value: config.clientID),
            sub: SubjectClaim(value: config.clientID),
            aud: AudienceClaim(value: [config.tokenURL.string]),
            exp: ExpirationClaim(value: now.addingTimeInterval(300)),
            iat: IssuedAtClaim(value: now),
            jti: UUID().uuidString
        )
        return try await keys.sign(claims, header: header)
    }
}

struct IBKROAuthTokenResponse: Content {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

private struct IBKRClientAssertionClaims: JWTPayload {
    let iss: IssuerClaim
    let sub: SubjectClaim
    let aud: AudienceClaim
    let exp: ExpirationClaim
    let iat: IssuedAtClaim
    let jti: String

    func verify(using _: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }
}

private func ibkrOAuthURLFormEncoded(_ parameters: [String: String]) throws -> String {
    try parameters
        .map { key, value in
            let encodedKey = try ibkrOAuthPercentEncode(key)
            let encodedValue = try ibkrOAuthPercentEncode(value)
            return "\(encodedKey)=\(encodedValue)"
        }
        .sorted()
        .joined(separator: "&")
}

private func ibkrOAuthPercentEncode(_ value: String) throws -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=?+")
    guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
        throw Abort(.internalServerError, reason: "Failed to percent-encode IBKR OAuth parameters.")
    }
    return encoded
}

private func ibkrOAuthExtractBody(from response: ClientResponse) -> String {
    response.body
        .flatMap { buffer in
            buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes)
        }?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
