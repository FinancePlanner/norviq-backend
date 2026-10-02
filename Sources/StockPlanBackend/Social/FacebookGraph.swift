import Crypto
import Foundation
import JWTKit
import Vapor

// MARK: - Limited Login (iOS)

/// Verifies a Facebook Limited Login id token. Pure apart from the keys, so
/// tests can sign with a local RSA key.
enum FacebookLimitedLogin {
    static let issuers: Set<String> = ["https://www.facebook.com", "https://facebook.com"]

    struct Claims: JWTPayload {
        let iss: String
        let aud: StringOrArray
        let exp: Int
        let iat: Int?
        let sub: String
        let nonce: String?
        let userFriends: FacebookFriendIDs?

        enum CodingKeys: String, CodingKey {
            case iss
            case aud
            case exp
            case iat
            case sub
            case nonce
            case userFriends = "user_friends"
        }

        func verify(using _: some JWTAlgorithm) throws {
            guard FacebookLimitedLogin.issuers.contains(iss) else {
                throw Abort(.unauthorized, reason: "Facebook id_token issuer is invalid")
            }
            try oauthValidateStandardTimes(exp: exp, iat: iat, providerLabel: "Facebook")
            guard !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Abort(.unauthorized, reason: "Facebook id_token is missing subject")
            }
        }
    }

    static func verify(_ idToken: String, nonce: String, appIDs: [String], jwks: JWKS) async throws -> Claims {
        let keys = JWTKeyCollection()
        do {
            try await keys.add(jwks: jwks)
        } catch {
            throw Abort(.badGateway, reason: "Facebook signing keys are unusable")
        }
        let claims: Claims = try await oauthVerifyIDToken(
            idToken,
            using: keys,
            allowedAlgorithms: ["RS256"],
            providerLabel: "Facebook"
        )
        guard appIDs.contains(where: claims.aud.contains) else {
            throw Abort(.unauthorized, reason: "Facebook id_token audience is invalid")
        }
        guard let tokenNonce = claims.nonce,
              OAuthServerService.constantTimeEquals(tokenNonce, nonce)
        else {
            throw Abort(.unauthorized, reason: "Facebook id_token nonce mismatch")
        }
        return claims
    }
}

/// The `user_friends` claim: `["id", ...]` or `[{"id": "..."}, ...]`
/// (an object wrapping `data` is accepted too). Unreadable entries are skipped.
struct FacebookFriendIDs: Codable, Sendable, Equatable {
    let ids: [String]

    private enum Entry: Decodable {
        case id(String)
        case unreadable

        private struct Object: Decodable {
            let id: String?
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let id = try? container.decode(String.self) {
                self = .id(id)
            } else if let id = try? container.decode(Object.self).id {
                self = .id(id)
            } else {
                self = .unreadable
            }
        }
    }

    private struct Wrapped: Decodable {
        let data: [Entry]
    }

    init(ids: [String]) {
        self.ids = ids
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let entries = (try? container.decode([Entry].self)) ?? (try? container.decode(Wrapped.self).data) ?? []
        ids = entries.compactMap { entry in
            if case let .id(id) = entry {
                return id
            }
            return nil
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ids)
    }
}

/// Where Limited Login signing keys come from. Swapped in tests.
protocol FacebookJWKSProvider: Sendable {
    /// `kid` lets a cache refetch early when Facebook rotates keys.
    func jwks(containing kid: String?, on req: Request) async throws -> JWKS
}

/// Caches Facebook's JWKS for an hour; an unknown `kid` triggers a refetch
/// at most once a minute. A failed refresh keeps serving the old keys.
actor FacebookJWKSCache: FacebookJWKSProvider {
    static let shared = FacebookJWKSCache()
    static let url = URI(string: "https://limited.facebook.com/.well-known/oauth/openid/jwks/")
    static let maxAge: TimeInterval = 3600
    static let minRefetchInterval: TimeInterval = 60

    private var cached: (jwks: JWKS, kids: Set<String>, fetchedAt: Date)?

    func jwks(containing kid: String?, on req: Request) async throws -> JWKS {
        let now = Date()
        if let cached {
            let age = now.timeIntervalSince(cached.fetchedAt)
            let knowsKid = kid.map(cached.kids.contains) ?? true
            if age < Self.maxAge, knowsKid || age < Self.minRefetchInterval {
                return cached.jwks
            }
        }
        do {
            let response = try await req.client.get(Self.url)
            guard response.status == .ok, let body = response.body else {
                throw Abort(.badGateway, reason: "Facebook JWKS returned \(response.status.code)")
            }
            let jwks = try JSONDecoder().decode(JWKS.self, from: Data(buffer: body))
            let kids = Set(jwks.keys.compactMap { $0.keyIdentifier?.string })
            cached = (jwks, kids, now)
            return jwks
        } catch {
            req.logger.warning("social.facebook_import jwks fetch failed: \(String(describing: error))")
            if let cached {
                return cached.jwks
            }
            throw Abort(.badGateway, reason: "Couldn't reach Facebook to check the sign-in. Please try again.")
        }
    }
}

// MARK: - Graph API (web)

struct FacebookGraphResponse: Sendable {
    let status: HTTPStatus
    let body: Data
}

/// HTTP to graph.facebook.com. Swapped in tests so they never hit the network.
protocol FacebookGraphClient: Sendable {
    func get(_ url: URI, bearer token: String, on req: Request) async throws -> FacebookGraphResponse
    func postForm(_ url: URI, form: String, on req: Request) async throws -> FacebookGraphResponse
}

struct LiveFacebookGraphClient: FacebookGraphClient {
    func get(_ url: URI, bearer token: String, on req: Request) async throws -> FacebookGraphResponse {
        let response = try await req.client.get(url) { clientRequest in
            clientRequest.headers.bearerAuthorization = .init(token: token)
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
        }
        return FacebookGraphResponse(status: response.status, body: response.body.map { Data(buffer: $0) } ?? Data())
    }

    func postForm(_ url: URI, form: String, on req: Request) async throws -> FacebookGraphResponse {
        let response = try await req.client.post(url) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .contentType, value: "application/x-www-form-urlencoded")
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            clientRequest.body = .init(string: form)
        }
        return FacebookGraphResponse(status: response.status, body: response.body.map { Data(buffer: $0) } ?? Data())
    }
}

/// The three Graph calls the web flow makes. Every call after the code
/// exchange carries `appsecret_proof`.
struct FacebookGraph {
    let client: any FacebookGraphClient
    let appID: String
    let appSecret: String
    let req: Request

    private struct TokenResponse: Decodable {
        let accessToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }

    private struct Me: Decodable {
        let id: String
    }

    private struct FriendsPage: Decodable {
        struct Friend: Decodable {
            let id: String
        }

        struct Paging: Decodable {
            let next: String?
        }

        let data: [Friend]?
        let paging: Paging?
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let code: Int?
            let type: String?
        }

        let error: Detail?
    }

    static func appSecretProof(token: String, secret: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(token.utf8), using: SymmetricKey(data: Data(secret.utf8)))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func exchangeCode(_ code: String, redirectURI: String) async throws -> String {
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: appID),
            URLQueryItem(name: "client_secret", value: appSecret),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code", value: code),
        ]
        // `+` survives URLComponents but means a space in a form body.
        let body = (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        let response = try await client.postForm(
            URI(string: "\(FacebookFriendsImport.graphBaseURL)/oauth/access_token"),
            form: body,
            on: req
        )
        guard response.status == .ok,
              let token = try? JSONDecoder().decode(TokenResponse.self, from: response.body).accessToken,
              !token.isEmpty
        else {
            req.logger.warning("social.facebook_import token exchange failed status=\(response.status.code)")
            // 400 is Facebook's answer to an expired, reused or mismatched code.
            if response.status == .badRequest {
                throw Abort(.unauthorized, reason: "Facebook didn't accept the sign-in. Please try again.")
            }
            throw Abort(.badGateway, reason: "Couldn't reach Facebook to finish the sign-in. Please try again.")
        }
        return token
    }

    func meID(token: String) async throws -> String {
        let me = try await fetch(Me.self, url: graphURL("/me", query: [("fields", "id")], token: token), token: token)
        return me.id
    }

    func friendIDs(token: String) async throws -> [String] {
        var ids: [String] = []
        var url: URI? = try graphURL("/me/friends", query: [("limit", "500")], token: token)
        for _ in 0 ..< FacebookFriendsImport.maxPages {
            guard let current = url else { break }
            let page = try await fetch(FriendsPage.self, url: current, token: token)
            ids.append(contentsOf: (page.data ?? []).map(\.id))
            url = try page.paging?.next.flatMap { try nextPageURL($0, token: token) }
        }
        return ids
    }

    private func graphURL(_ path: String, query: [(String, String)], token: String) throws -> URI {
        var components = URLComponents(string: "\(FacebookFriendsImport.graphBaseURL)\(path)")
        components?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            + [URLQueryItem(name: "appsecret_proof", value: Self.appSecretProof(token: token, secret: appSecret))]
        guard let string = components?.string else {
            throw Abort(.internalServerError, reason: "Failed to build Facebook Graph URL")
        }
        return URI(string: string)
    }

    /// Follows `paging.next` only on graph.facebook.com. The token goes in
    /// the Authorization header, so it is stripped from the query, and the
    /// proof is (re)set.
    private func nextPageURL(_ raw: String, token: String) throws -> URI? {
        guard var components = URLComponents(string: raw),
              components.scheme == "https",
              components.host == "graph.facebook.com"
        else {
            req.logger.warning("social.facebook_import ignoring unexpected paging.next host")
            return nil
        }
        var items = (components.queryItems ?? []).filter { $0.name != "access_token" && $0.name != "appsecret_proof" }
        items.append(URLQueryItem(name: "appsecret_proof", value: Self.appSecretProof(token: token, secret: appSecret)))
        components.queryItems = items
        return components.string.map { URI(string: $0) }
    }

    private func fetch<T: Decodable>(_: T.Type, url: URI, token: String) async throws -> T {
        let response = try await client.get(url, bearer: token, on: req)
        guard response.status == .ok else {
            let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: response.body))?.error?.code
            req.logger.warning(
                "social.facebook_import graph request failed status=\(response.status.code) code=\(code.map(String.init) ?? "-")"
            )
            switch code {
            case 190:
                throw Abort(.unauthorized, reason: "Facebook sign-in expired. Please try again.")
            case 4, 17, 32, 613:
                throw Abort(.badGateway, reason: "Facebook is rate limiting this right now. Try again in a few minutes.")
            default:
                throw Abort(.badGateway, reason: "Couldn't read your friends from Facebook.")
            }
        }
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw Abort(.badGateway, reason: "Facebook returned an unexpected response.")
        }
    }
}

// MARK: - Injection

extension Application {
    struct FacebookGraphClientKey: StorageKey {
        typealias Value = any FacebookGraphClient
    }

    struct FacebookJWKSProviderKey: StorageKey {
        typealias Value = any FacebookJWKSProvider
    }

    var facebookGraphClient: any FacebookGraphClient {
        get { storage[FacebookGraphClientKey.self] ?? LiveFacebookGraphClient() }
        set { storage[FacebookGraphClientKey.self] = newValue }
    }

    var facebookJWKSProvider: any FacebookJWKSProvider {
        get { storage[FacebookJWKSProviderKey.self] ?? FacebookJWKSCache.shared }
        set { storage[FacebookJWKSProviderKey.self] = newValue }
    }
}
