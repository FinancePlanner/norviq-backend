import _CryptoExtras
import Fluent
import FluentSQL
import Foundation
import JWTKit
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

// MARK: - Fixtures

/// Signs Limited Login-shaped tokens with a throwaway RSA key and exposes the
/// matching JWKS, standing in for limited.facebook.com.
private struct FacebookTestSigner {
    static let kid = "fb-test"
    let keys: JWTKeyCollection
    let jwks: JWKS

    static func make() async throws -> FacebookTestSigner {
        let privateKey = try Insecure.RSA.PrivateKey(backing: _RSA.Signing.PrivateKey(keySize: .bits2048))
        let primitives = try privateKey.publicKey.getKeyPrimitives()
        let jwk = JWK.rsa(
            .rs256,
            identifier: JWKIdentifier(string: kid),
            modulus: primitives.modulus.base64URL,
            exponent: primitives.publicExponent.base64URL
        )
        let keys = JWTKeyCollection()
        await keys.add(rsa: privateKey, digestAlgorithm: .sha256, kid: JWKIdentifier(string: kid))
        await keys.add(
            hmac: HMACKey(from: "an-hmac-key-that-is-not-facebooks-rsa-key"),
            digestAlgorithm: .sha256,
            kid: "hs"
        )
        return FacebookTestSigner(keys: keys, jwks: JWKS(keys: [jwk]))
    }

    func token(_ claims: FacebookTestClaims, kid: String = Self.kid) async throws -> String {
        try await keys.sign(claims, kid: JWKIdentifier(string: kid))
    }
}

private struct FacebookTestClaims: JWTPayload {
    enum Friends {
        case strings([String])
        case objects([String])
    }

    var iss = "https://www.facebook.com"
    var aud = "222"
    var exp = Int(Date().timeIntervalSince1970) + 600
    var iat = Int(Date().timeIntervalSince1970)
    var sub = "fb-a"
    var nonce: String? = "raw-nonce-123"
    var friends: Friends?

    enum CodingKeys: String, CodingKey {
        case iss, aud, exp, iat, sub, nonce
        case friends = "user_friends"
    }

    init(sub: String = "fb-a", friends: Friends? = nil) {
        self.sub = sub
        self.friends = friends
    }

    init(from _: any Decoder) throws {
        throw Abort(.notImplemented)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(iss, forKey: .iss)
        try container.encode(aud, forKey: .aud)
        try container.encode(exp, forKey: .exp)
        try container.encode(iat, forKey: .iat)
        try container.encode(sub, forKey: .sub)
        try container.encodeIfPresent(nonce, forKey: .nonce)
        switch friends {
        case let .strings(ids):
            try container.encode(ids, forKey: .friends)
        case let .objects(ids):
            try container.encode(ids.map { ["id": $0, "name": "Friend \($0)"] }, forKey: .friends)
        case nil:
            break
        }
    }

    func verify(using _: some JWTAlgorithm) throws {}
}

private struct StaticFacebookJWKS: FacebookJWKSProvider {
    let jwks: JWKS

    func jwks(containing _: String?, on _: Request) async throws -> JWKS {
        jwks
    }
}

/// Graph API stand-in. Friends come back in pages linked by `paging.next`;
/// every Graph call must carry a valid `appsecret_proof` and no query token.
private final class FakeFacebookGraph: FacebookGraphClient, @unchecked Sendable {
    static let secret = "test-app-secret"
    let meID: String
    let pages: [[String]]
    private let lock = NSLock()
    private var _requested: [String] = []

    var requested: [String] {
        lock.withLock { _requested }
    }

    init(meID: String, pages: [[String]]) {
        self.meID = meID
        self.pages = pages
    }

    private var token: String {
        "token-\(meID)"
    }

    func postForm(_ url: URI, form: String, on _: Request) async throws -> FacebookGraphResponse {
        lock.withLock { _requested.append(url.string) }
        let fields = URLComponents(string: "?\(form)")?.queryItems ?? []
        let value = { (name: String) in fields.first { $0.name == name }?.value }
        guard url.path.hasSuffix("/oauth/access_token"),
              value("client_secret") == Self.secret,
              value("client_id") == "111",
              value("code") == "good-code"
        else {
            return Self.json(.badRequest, #"{"error":{"message":"Invalid verification code","type":"OAuthException","code":100}}"#)
        }
        return Self.json(.ok, #"{"access_token":"\#(token)","token_type":"bearer"}"#)
    }

    func get(_ url: URI, bearer: String, on _: Request) async throws -> FacebookGraphResponse {
        lock.withLock { _requested.append(url.string) }
        let items = URLComponents(string: url.string)?.queryItems ?? []
        let proof = items.first { $0.name == "appsecret_proof" }?.value
        guard bearer == token,
              proof == FacebookGraph.appSecretProof(token: token, secret: Self.secret),
              !items.contains(where: { $0.name == "access_token" })
        else {
            return Self.json(.badRequest, #"{"error":{"message":"bad proof","type":"OAuthException","code":190}}"#)
        }
        if url.path.hasSuffix("/me") {
            return Self.json(.ok, #"{"id":"\#(meID)"}"#)
        }
        let page = Int(items.first { $0.name == "after" }?.value ?? "0") ?? 0
        let data = pages[page].map { #"{"id":"\#($0)","name":"n"}"# }.joined(separator: ",")
        let next = page + 1 < pages.count
            ? #","next":"https://graph.facebook.com/v21.0/me/friends?limit=500&after=\#(page + 1)&access_token=\#(token)""#
            : ""
        return Self.json(.ok, #"{"data":[\#(data)],"paging":{"cursors":{}\#(next)}}"#)
    }

    private static func json(_ status: HTTPStatus, _ body: String) -> FacebookGraphResponse {
        FacebookGraphResponse(status: status, body: Data(body.utf8))
    }
}

private struct NoBody: Decodable {}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Token verification

@Suite("Facebook Limited Login token")
struct FacebookLimitedLoginTokenTests {
    private let appIDs = ["111", "222"]

    private func verify(
        _ claims: FacebookTestClaims,
        nonce: String = "raw-nonce-123",
        kid: String = FacebookTestSigner.kid
    ) async throws -> FacebookLimitedLogin.Claims {
        let signer = try await FacebookTestSigner.make()
        let token = try await signer.token(claims, kid: kid)
        return try await FacebookLimitedLogin.verify(token, nonce: nonce, appIDs: appIDs, jwks: signer.jwks)
    }

    private func expectUnauthorized(
        _ claims: FacebookTestClaims,
        nonce: String = "raw-nonce-123",
        kid: String = FacebookTestSigner.kid
    ) async {
        await #expect {
            _ = try await verify(claims, nonce: nonce, kid: kid)
        } throws: { error in
            (error as? any AbortError)?.status == .unauthorized
        }
    }

    @Test("Friend ids as plain strings; aud may be any configured app id")
    func validStringFriends() async throws {
        let claims = try await verify(FacebookTestClaims(friends: .strings(["f1", "f2"])))
        #expect(claims.sub == "fb-a")
        #expect(claims.userFriends?.ids == ["f1", "f2"])
    }

    @Test("Friend ids as {id} objects")
    func validObjectFriends() async throws {
        var input = FacebookTestClaims(friends: .objects(["f3", "f4"]))
        input.iss = "https://facebook.com"
        let claims = try await verify(input)
        #expect(claims.userFriends?.ids == ["f3", "f4"])
    }

    @Test("No user_friends claim means no friends")
    func missingFriends() async throws {
        let claims = try await verify(FacebookTestClaims())
        #expect(claims.userFriends == nil)
    }

    @Test("Wrong audience is rejected")
    func wrongAudience() async {
        var claims = FacebookTestClaims()
        claims.aud = "999"
        await expectUnauthorized(claims)
    }

    @Test("Wrong issuer is rejected")
    func wrongIssuer() async {
        var claims = FacebookTestClaims()
        claims.iss = "https://evil.example.com"
        await expectUnauthorized(claims)
    }

    @Test("Nonce must match the one the app generated")
    func badNonce() async {
        await expectUnauthorized(FacebookTestClaims(), nonce: "raw-nonce-124")
        var missing = FacebookTestClaims()
        missing.nonce = nil
        await expectUnauthorized(missing)
    }

    @Test("Expired tokens are rejected")
    func expired() async {
        var claims = FacebookTestClaims()
        claims.exp = Int(Date().timeIntervalSince1970) - 3600
        claims.iat = claims.exp - 600
        await expectUnauthorized(claims)
    }

    @Test("Only RS256 is accepted")
    func nonRS256() async {
        await expectUnauthorized(FacebookTestClaims(), kid: "hs")
    }
}

// MARK: - Routes

/// Link, match, unlink and the web flow against a real database.
@Suite("Social Facebook import", .serialized)
struct SocialFacebookImportRouteTests {
    static let redirectURI = "https://norviq.test/friends/facebook/callback"

    private func withApp(
        importEnabled: Bool = true,
        graph: FakeFacebookGraph? = nil,
        _ test: (Application, FacebookTestSigner) async throws -> Void
    ) async throws {
        let signer = try await FacebookTestSigner.make()
        try await DatabaseTestLock.withLock {
            setenv("SOCIAL_ENABLED", "1", 1)
            setenv("SOCIAL_CONTACT_PEPPER", "test-pepper", 1)
            setenv("FACEBOOK_APP_ID", "111, 222", 1)
            setenv("FACEBOOK_APP_SECRET", FakeFacebookGraph.secret, 1)
            setenv("OAUTH_ALLOWED_REDIRECT_URIS", Self.redirectURI, 1)
            if importEnabled {
                setenv("SOCIAL_FACEBOOK_IMPORT_ENABLED", "1", 1)
            } else {
                unsetenv("SOCIAL_FACEBOOK_IMPORT_ENABLED")
            }
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                app.facebookJWKSProvider = StaticFacebookJWKS(jwks: signer.jwks)
                if let graph {
                    app.facebookGraphClient = graph
                }
                try await app.autoMigrate()
                try await test(app, signer)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func register(_ app: Application, _ id: String) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "fb_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "fb+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var response: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })
        return try #require(response)
    }

    private func bearer(_ auth: AuthResponse) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = BearerAuthorization(token: auth.token)
        return headers
    }

    /// Status, decoded body when 200, and the error reason otherwise.
    private func call<T: Decodable>(
        _ app: Application, _ method: HTTPMethod, _ path: String, as auth: AuthResponse,
        body: (any Content)? = nil, _: T.Type
    ) async throws -> (status: HTTPStatus, value: T?, reason: String?) {
        var result: (HTTPStatus, T?, String?) = (.internalServerError, nil, nil)
        try await app.testing().test(method, path, headers: bearer(auth), beforeRequest: { req in
            if let body {
                try req.content.encode(body)
            }
        }, afterResponse: { res async throws in
            let value = res.status == .ok ? try? res.content.decode(T.self) : nil
            let reason = try? res.content.get(String.self, at: "reason")
            result = (res.status, value, reason)
        })
        return result
    }

    private func limited(
        _ app: Application, _ signer: FacebookTestSigner, as auth: AuthResponse,
        sub: String, friends: [String]?, nonce: String = "raw-nonce-123"
    ) async throws -> (status: HTTPStatus, value: SocialFacebookMatchesResponse?, reason: String?) {
        let token = try await signer.token(FacebookTestClaims(sub: sub, friends: friends.map { .strings($0) }))
        return try await call(app, .POST, "v1/social/discovery/facebook/limited", as: auth,
                              body: SocialFacebookLimitedLoginBody(idToken: token, nonce: nonce),
                              SocialFacebookMatchesResponse.self)
    }

    private func storedFriends(_ app: Application, of userId: UUID) async throws -> [String] {
        let sql = try #require(app.db as? any SQLDatabase)
        struct Row: Decodable {
            let facebook_id: String
        }
        return try await sql.select().column("facebook_id").from("social_facebook_friends")
            .where("user_id", .equal, SQLBind(userId))
            .orderBy("facebook_id")
            .all(decoding: Row.self)
            .map(\.facebook_id)
    }

    private func facebookIdentities(_ app: Application, of userId: UUID) async throws -> [String] {
        try await OAuthIdentity.query(on: app.db)
            .filter(\.$user.$id == userId)
            .filter(\.$provider == "facebook")
            .all()
            .map(\.providerUserID)
    }

    @Test("Off unless SOCIAL_FACEBOOK_IMPORT_ENABLED; linking 404s while off, unlinking still works")
    func disabledByDefault() async throws {
        try await withApp(importEnabled: false) { app, signer in
            let a = try await register(app, "off1")
            let config = try await call(app, .GET, "v1/social/config", as: a, SocialConfigDTO.self)
            #expect(config.value?.facebookImport == false)
            #expect(try await limited(app, signer, as: a, sub: "fb-a", friends: []).status == .notFound)
            let start = try await call(app, .POST, "v1/social/discovery/facebook/start", as: a,
                                       body: OAuthStartRequest(redirectURI: Self.redirectURI), StockPlanBackend.OAuthStartResponse.self)
            #expect(start.status == .notFound)
            let exchange = try await call(app, .POST, "v1/social/discovery/facebook/exchange", as: a,
                                          body: StockPlanBackend.OAuthExchangeRequest(flowId: UUID(), code: "c", state: "s",
                                                                                      redirectURI: Self.redirectURI),
                                          SocialFacebookMatchesResponse.self)
            #expect(exchange.status == .notFound)
            // Removing your Facebook data never depends on the switch: the
            // data-deletion page promises it works whenever you ask.
            #expect(try await call(app, .DELETE, "v1/social/discovery/facebook", as: a, NoBody.self).status == .noContent)
        }
    }

    @Test("Config turns on with the env flag and an app id")
    func enabledConfig() async throws {
        try await withApp { app, _ in
            let a = try await register(app, "on1")
            let config = try await call(app, .GET, "v1/social/config", as: a, SocialConfigDTO.self)
            #expect(config.value?.facebookImport == true)
            #expect(config.value?.xImport == false)
        }
    }

    @Test("Limited Login links the account and returns linked friends; a bad token is 401")
    func limitedLinksAndMatches() async throws {
        try await withApp { app, signer in
            let a = try await register(app, "lim1")
            let b = try await register(app, "lim2")
            #expect(try await limited(app, signer, as: b, sub: "fb-b", friends: nil).value?.friendsGranted == 0)

            let result = try await limited(app, signer, as: a, sub: "fb-a", friends: ["fb-b", "fb-nobody"])
            #expect(result.status == .ok)
            #expect(result.value?.friendsGranted == 2)
            #expect(result.value?.matches.map(\.user.id) == [b.userId])
            #expect(try await facebookIdentities(app, of: a.userId) == ["fb-a"])
            #expect(try await storedFriends(app, of: a.userId) == ["fb-b", "fb-nobody"])

            let badNonce = try await limited(app, signer, as: a, sub: "fb-a", friends: [], nonce: "other")
            #expect(badNonce.status == .unauthorized)
            // A rejected token leaves the stored list alone.
            #expect(try await storedFriends(app, of: a.userId) == ["fb-b", "fb-nobody"])
        }
    }

    @Test("A Facebook account links to one Norviq user; relinking replaces the friend list")
    func linking() async throws {
        try await withApp { app, signer in
            let a = try await register(app, "link1")
            let b = try await register(app, "link2")
            #expect(try await limited(app, signer, as: a, sub: "fb-a", friends: ["f1", "f2"]).status == .ok)

            let stolen = try await limited(app, signer, as: b, sub: "fb-a", friends: ["f9"])
            #expect(stolen.status == .conflict)
            #expect(stolen.reason == "This Facebook account is already connected to another Norviq account.")
            #expect(try await facebookIdentities(app, of: b.userId).isEmpty)
            #expect(try await storedFriends(app, of: b.userId).isEmpty)

            #expect(try await limited(app, signer, as: a, sub: "fb-a", friends: ["f3"]).status == .ok)
            #expect(try await storedFriends(app, of: a.userId) == ["f3"])

            // Switching Facebook accounts drops the old link: one per user.
            #expect(try await limited(app, signer, as: a, sub: "fb-a2", friends: []).status == .ok)
            #expect(try await facebookIdentities(app, of: a.userId) == ["fb-a2"])
            #expect(try await storedFriends(app, of: a.userId).isEmpty)
            // ...which frees the first one for someone else.
            #expect(try await limited(app, signer, as: b, sub: "fb-a", friends: []).status == .ok)
        }
    }

    @Test("Matches skip blocked users and people who turned Facebook discovery off")
    func matchingRespectsPrivacy() async throws {
        try await withApp { app, signer in
            let a = try await register(app, "match1")
            let b = try await register(app, "match2")
            let c = try await register(app, "match3")
            let d = try await register(app, "match4")
            for (user, fbId) in [(b, "fb-b"), (c, "fb-c"), (d, "fb-d")] {
                _ = try await FacebookFriendsImport.linkAndMatch(
                    userId: user.userId, facebookId: fbId, friendIds: [], on: app.db
                )
            }
            #expect(try await call(app, .POST, "v1/social/blocks/\(a.userId)", as: c, NoBody.self).status
                == .noContent)

            var privacy = try #require(
                try await call(app, .GET, "v1/social/privacy", as: d, SocialPrivacySettingsDTO.self).value
            )
            #expect(privacy.discoverableByFacebook)
            privacy.discoverableByFacebook = false
            let updated = try await call(app, .PUT, "v1/social/privacy", as: d, body: privacy,
                                         SocialPrivacySettingsDTO.self)
            #expect(updated.value?.discoverableByFacebook == false)

            let result = try await limited(app, signer, as: a, sub: "fb-a", friends: ["fb-b", "fb-c", "fb-d", "fb-x"])
            #expect(result.value?.friendsGranted == 4)
            #expect(result.value?.matches.map(\.user.id) == [b.userId])
        }
    }

    @Test("Older apps saving privacy without the Facebook field keep the stored value")
    func privacyWithoutFacebookField() async throws {
        try await withApp { app, _ in
            let a = try await register(app, "priv1")
            var privacy = try #require(
                try await call(app, .GET, "v1/social/privacy", as: a, SocialPrivacySettingsDTO.self).value
            )
            privacy.discoverableByFacebook = false
            _ = try await call(app, .PUT, "v1/social/privacy", as: a, body: privacy, SocialPrivacySettingsDTO.self)

            struct LegacyPrivacy: Content {
                var searchVisibility = "everyone"
                var discoverableByContacts = true
                var discoverableByX = true
                var showReturnPercent = true
                var showStreaks = true
                var showXP = true
                var leaderboardOptIn = true
            }
            let saved = try await call(app, .PUT, "v1/social/privacy", as: a, body: LegacyPrivacy(),
                                       SocialPrivacySettingsDTO.self)
            #expect(saved.status == .ok)
            #expect(saved.value?.showReturnPercent == true)
            #expect(saved.value?.discoverableByFacebook == false)
        }
    }

    @Test("Web flow: exchange follows Graph paging, and a flow works once")
    func webExchange() async throws {
        let graph = FakeFacebookGraph(meID: "fb-web", pages: [["fb-b", "f2"], ["f3"], ["f4"]])
        try await withApp(graph: graph) { app, _ in
            let a = try await register(app, "web1")
            let b = try await register(app, "web2")
            _ = try await FacebookFriendsImport.linkAndMatch(userId: b.userId, facebookId: "fb-b", friendIds: [], on: app.db)

            let start = try await call(app, .POST, "v1/social/discovery/facebook/start", as: a,
                                       body: OAuthStartRequest(redirectURI: Self.redirectURI), StockPlanBackend.OAuthStartResponse.self)
            let started = try #require(start.value)
            let url = try #require(URLComponents(string: started.authorizationURL))
            let query = { (name: String) in url.queryItems?.first { $0.name == name }?.value }
            #expect(url.host == "www.facebook.com")
            #expect(url.path == "/v21.0/dialog/oauth")
            #expect(query("client_id") == "111")
            #expect(query("scope") == "public_profile,user_friends")
            #expect(query("response_type") == "code")
            #expect(query("redirect_uri") == Self.redirectURI)
            let state = try #require(query("state"))

            let body = StockPlanBackend.OAuthExchangeRequest(flowId: started.flowId, code: "good-code", state: state,
                                                             redirectURI: Self.redirectURI)
            let result = try await call(app, .POST, "v1/social/discovery/facebook/exchange", as: a, body: body,
                                        SocialFacebookMatchesResponse.self)
            #expect(result.status == .ok)
            #expect(result.value?.friendsGranted == 4)
            #expect(result.value?.matches.map(\.user.id) == [b.userId])
            #expect(graph.requested.count(where: { $0.contains("/me/friends") }) == 3)
            #expect(try await facebookIdentities(app, of: a.userId) == ["fb-web"])
            #expect(try await storedFriends(app, of: a.userId) == ["f2", "f3", "f4", "fb-b"])

            let replay = try await call(app, .POST, "v1/social/discovery/facebook/exchange", as: a, body: body,
                                        SocialFacebookMatchesResponse.self)
            #expect(replay.status == .unauthorized)
        }
    }

    @Test("Web flow: expired flows, other users' flows, bad state and rejected codes fail")
    func webExchangeFailures() async throws {
        let graph = FakeFacebookGraph(meID: "fb-web", pages: [[]])
        try await withApp(graph: graph) { app, _ in
            let a = try await register(app, "webf1")
            let b = try await register(app, "webf2")
            func start() async throws -> (UUID, String) {
                let started = try #require(try await call(
                    app, .POST, "v1/social/discovery/facebook/start", as: a,
                    body: OAuthStartRequest(redirectURI: Self.redirectURI), StockPlanBackend.OAuthStartResponse.self
                ).value)
                let state = URLComponents(string: started.authorizationURL)?.queryItems?
                    .first { $0.name == "state" }?.value
                return try (started.flowId, #require(state))
            }
            func exchange(_ flowId: UUID, _ state: String, code: String = "good-code", as user: AuthResponse? = nil)
                async throws -> HTTPStatus
            {
                try await call(app, .POST, "v1/social/discovery/facebook/exchange", as: user ?? a,
                               body: StockPlanBackend.OAuthExchangeRequest(flowId: flowId, code: code, state: state,
                                                                           redirectURI: Self.redirectURI),
                               SocialFacebookMatchesResponse.self).status
            }

            let (expiredId, expiredState) = try await start()
            let flow = try #require(try await OAuthFlow.find(expiredId, on: app.db))
            flow.expiresAt = Date().addingTimeInterval(-1)
            try await flow.save(on: app.db)
            #expect(try await exchange(expiredId, expiredState) == .unauthorized)

            let (otherId, otherState) = try await start()
            #expect(try await exchange(otherId, otherState, as: b) == .unauthorized)
            #expect(try await exchange(otherId, "wrong-state") == .unauthorized)

            let (badCodeId, badCodeState) = try await start()
            #expect(try await exchange(badCodeId, badCodeState, code: "bad-code") == .unauthorized)
            #expect(try await facebookIdentities(app, of: a.userId).isEmpty)
        }
    }

    @Test("Web flow is unavailable without the app secret; iOS still works")
    func webNeedsSecret() async throws {
        try await withApp { app, signer in
            unsetenv("FACEBOOK_APP_SECRET")
            let a = try await register(app, "nosecret1")
            let start = try await call(app, .POST, "v1/social/discovery/facebook/start", as: a,
                                       body: OAuthStartRequest(redirectURI: Self.redirectURI), StockPlanBackend.OAuthStartResponse.self)
            #expect(start.status == .notFound)
            #expect(try await limited(app, signer, as: a, sub: "fb-a", friends: []).status == .ok)
        }
    }

    @Test("DELETE unlinks Facebook and forgets the friend list")
    func disconnect() async throws {
        try await withApp { app, signer in
            let a = try await register(app, "del1")
            #expect(try await limited(app, signer, as: a, sub: "fb-a", friends: ["f1", "f2"]).status == .ok)
            #expect(try await call(app, .DELETE, "v1/social/discovery/facebook", as: a, NoBody.self).status
                == .noContent)
            #expect(try await facebookIdentities(app, of: a.userId).isEmpty)
            #expect(try await storedFriends(app, of: a.userId).isEmpty)
        }
    }
}
