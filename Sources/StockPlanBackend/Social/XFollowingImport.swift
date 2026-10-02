import Crypto
import Fluent
import Foundation
import Vapor

/// "Find friends from X": a one-off OAuth flow with `follows.read` that reads
/// who the caller follows and returns the ones already on Norviq.
///
/// The X token is used for this one request and never stored. Only people
/// who signed in with (or linked) X and allow `discoverableByX` can match.
enum XFollowingImport {
    static let flowPurpose = "social_x_import"
    static let scopes = "tweet.read users.read follows.read"
    /// X caps a page at 1,000; five pages covers all but very large accounts
    /// while staying well inside the Basic tier's rate limit.
    static let maxPages = 5

    @Sendable
    static func start(req: Request) async throws -> OAuthStartResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        let config = try requireConfig()
        let body = try req.content.decode(OAuthStartRequest.self)
        let redirectURI = try validatedRedirectURI(body.redirectURI, app: req.application)

        let state = randomURLSafeString(length: 32)
        let codeVerifier = randomURLSafeString(length: 64)
        let expiresIn = 600
        let flow = OAuthFlow(
            provider: OAuthProvider.x.rawValue,
            state: state,
            nonce: randomURLSafeString(length: 32),
            codeVerifier: codeVerifier,
            redirectURI: redirectURI,
            purpose: flowPurpose,
            userId: userId,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
        )
        try await flow.save(on: req.db)
        guard let flowId = flow.id else {
            throw Abort(.internalServerError, reason: "OAuth flow id missing")
        }

        guard var components = URLComponents(url: config.authURL, resolvingAgainstBaseURL: false) else {
            throw Abort(.internalServerError, reason: "Failed to build X authorization URL")
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge(for: codeVerifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else {
            throw Abort(.internalServerError, reason: "Failed to build X authorization URL")
        }
        return OAuthStartResponse(flowId: flowId, authorizationURL: url.absoluteString, expiresIn: expiresIn)
    }

    @Sendable
    static func exchange(req: Request) async throws -> SocialXImportMatchesResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        let config = try requireConfig()
        let body = try req.content.decode(OAuthExchangeRequest.self)
        let redirectURI = try normalizedRedirectURI(body.redirectURI)

        guard let flow = try await OAuthFlow.find(body.flowId, on: req.db),
              flow.provider == OAuthProvider.x.rawValue,
              flow.purpose == flowPurpose,
              flow.userId == userId,
              flow.usedAt == nil,
              flow.expiresAt > Date()
        else {
            throw Abort(.unauthorized, reason: "X import flow is invalid or expired")
        }
        guard flow.state == body.state.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw Abort(.unauthorized, reason: "OAuth state mismatch")
        }
        guard flow.redirectURI == redirectURI else {
            throw Abort(.unauthorized, reason: "OAuth redirect URI mismatch")
        }
        flow.usedAt = Date()
        try await flow.save(on: req.db)

        let accessToken = try await exchangeCode(
            body.code.trimmingCharacters(in: .whitespacesAndNewlines),
            redirectURI: redirectURI,
            codeVerifier: flow.codeVerifier,
            config: config,
            on: req
        )
        let me = try await fetch(XUserEnvelope.self, from: "https://api.twitter.com/2/users/me", token: accessToken, on: req)
        let following = try await fetchFollowing(of: me.data.id, token: accessToken, on: req)

        let handles = Dictionary(following.map { ($0.id, $0.username ?? $0.id) }, uniquingKeysWith: { first, _ in first })
        let identities = handles.isEmpty ? [] : try await OAuthIdentity.query(on: req.db)
            .filter(\.$provider == OAuthProvider.x.rawValue)
            .filter(\.$providerUserID ~~ Array(handles.keys))
            .all()

        var handleByUser: [UUID: String] = [:]
        for identity in identities where identity.$user.id != userId {
            handleByUser[identity.$user.id] = handles[identity.providerUserID]
        }
        let hidden = try await SocialService.blockedEitherWay(for: userId, on: req.db)
        let candidates = handleByUser.keys.filter { !hidden.contains($0) }
        let settings = try await SocialService.settings(for: Array(candidates), on: req.db)
        let allowed = candidates.filter { settings[$0]?.discoverableByX ?? true }
        let summaries = try await SocialService.summaries(for: Array(allowed), viewer: userId, on: req.db)

        let matches = allowed.compactMap { id -> SocialXImportMatch? in
            guard let user = summaries[id], let handle = handleByUser[id] else { return nil }
            return SocialXImportMatch(xHandle: handle, user: user)
        }
        .sorted { $0.xHandle.lowercased() < $1.xHandle.lowercased() }
        return SocialXImportMatchesResponse(matches: matches, totalFollowingScanned: following.count)
    }

    // MARK: - X API

    struct XUser: Decodable {
        let id: String
        let username: String?
    }

    struct XUserEnvelope: Decodable {
        let data: XUser
    }

    struct XFollowingPage: Decodable {
        struct Meta: Decodable {
            let nextToken: String?

            enum CodingKeys: String, CodingKey {
                case nextToken = "next_token"
            }
        }

        let data: [XUser]?
        let meta: Meta?
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }

    private static func requireConfig() throws -> XOAuthProviderClient.Config {
        guard SocialConfiguration.fromEnvironment().xImport,
              let config = XOAuthProviderClient.Config.fromEnvironment()
        else {
            throw Abort(.notFound, reason: "X import is not available.")
        }
        return config
    }

    private static func exchangeCode(
        _ code: String,
        redirectURI: String,
        codeVerifier: String,
        config: XOAuthProviderClient.Config,
        on req: Request
    ) async throws -> String {
        guard !code.isEmpty else {
            throw Abort(.badRequest, reason: "OAuth authorization code is required")
        }
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "client_id", value: config.clientID),
        ]
        let response = try await req.client.post(config.tokenURL) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .contentType, value: "application/x-www-form-urlencoded")
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            if let secret = config.clientSecret {
                let encoded = Data("\(config.clientID):\(secret)".utf8).base64EncodedString()
                clientRequest.headers.replaceOrAdd(name: .authorization, value: "Basic \(encoded)")
            }
            clientRequest.body = .init(string: form.percentEncodedQuery ?? "")
        }
        guard response.status == .ok,
              let body = response.body,
              let token = try? JSONDecoder().decode(TokenResponse.self, from: Data(buffer: body)).accessToken,
              !token.isEmpty
        else {
            req.logger.warning("social.x_import token exchange failed status=\(response.status.code)")
            throw Abort(.badGateway, reason: "X didn't accept the sign-in. Please try again.")
        }
        return token
    }

    private static func fetchFollowing(of xUserId: String, token: String, on req: Request) async throws -> [XUser] {
        var users: [XUser] = []
        var nextToken: String?
        for _ in 0 ..< maxPages {
            var components = URLComponents(string: "https://api.twitter.com/2/users/\(xUserId)/following")
            var items = [
                URLQueryItem(name: "max_results", value: "1000"),
                URLQueryItem(name: "user.fields", value: "username"),
            ]
            if let nextToken {
                items.append(URLQueryItem(name: "pagination_token", value: nextToken))
            }
            components?.queryItems = items
            guard let url = components?.string else { break }
            let page = try await fetch(XFollowingPage.self, from: url, token: token, on: req)
            users.append(contentsOf: page.data ?? [])
            guard let next = page.meta?.nextToken, !next.isEmpty else { break }
            nextToken = next
        }
        return users
    }

    private static func fetch<T: Decodable>(_: T.Type, from url: String, token: String, on req: Request) async throws -> T {
        let response = try await req.client.get(URI(string: url)) { clientRequest in
            clientRequest.headers.bearerAuthorization = .init(token: token)
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
        }
        guard response.status == .ok, let body = response.body else {
            req.logger.warning("social.x_import request failed status=\(response.status.code)")
            let reason = response.status == .tooManyRequests
                ? "X is rate limiting this right now. Try again in 15 minutes."
                : "Couldn't read who you follow on X."
            throw Abort(.badGateway, reason: reason)
        }
        return try JSONDecoder().decode(T.self, from: Data(buffer: body))
    }

    // MARK: - OAuth helpers (same rules as sign-in; Facebook import reuses them)

    static func normalizedRedirectURI(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme, !scheme.isEmpty,
              let normalized = components.url?.absoluteString
        else {
            throw Abort(.badRequest, reason: "Invalid OAuth redirect URI")
        }
        return normalized
    }

    /// Mirrors `AuthService.validateRedirectURI`: the same
    /// `OAUTH_ALLOWED_REDIRECT_URIS` allowlist, required in production.
    static func validatedRedirectURI(_ raw: String, app: Application) throws -> String {
        let redirectURI = try normalizedRedirectURI(raw)
        let allowlist = Set(
            (Environment.get("OAUTH_ALLOWED_REDIRECT_URIS") ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        if allowlist.isEmpty {
            if app.environment == .production {
                throw Abort(.serviceUnavailable, reason: "OAuth redirect allowlist is not configured")
            }
            return redirectURI
        }
        guard allowlist.contains(redirectURI) else {
            throw Abort(.badRequest, reason: "OAuth redirect URI is not allowed")
        }
        return redirectURI
    }

    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).socialBase64URL
    }

    static func randomURLSafeString(length: Int) -> String {
        let bytes = (0 ..< max(length, 32)).map { _ in UInt8.random(in: 0 ... 255) }
        return String(Data(bytes).socialBase64URL.prefix(length))
    }
}

private extension Data {
    var socialBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
