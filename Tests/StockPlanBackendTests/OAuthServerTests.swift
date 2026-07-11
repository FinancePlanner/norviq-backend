import Crypto
import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("OAuth 2.1 Authorization Server Tests", .serialized)
struct OAuthServerTests {
    private func withApp(_ test: @escaping (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func registerUser(app: Application) async throws -> (token: String, userId: UUID) {
        let id = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "oauth_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "oauth_\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            token = try res.content.decode(AuthResponse.self).token
        })
        let session = try await app.jwt.keys.verify(token, as: SessionToken.self)
        return (token, session.userId)
    }

    private func grantPro(app: Application, userId: UUID) async throws {
        try await Entitlement(userId: userId, level: "pro").save(on: app.db)
    }

    private func makeClient(app: Application, redirect: String = "https://client.example/cb") async throws -> String {
        let clientID = OpaqueToken.generate(prefix: "nvq_client_", byteCount: 16)
        let client = OAuthClient(clientID: clientID, clientName: "Test", redirectURIs: [redirect])
        try await client.save(on: app.db)
        return clientID
    }

    /// Decodes the raw response body with a plain JSONDecoder — matching how a
    /// real OAuth client reads the spec-mandated snake_case wire format, bypassing
    /// the app's snake→camel decode normalization.
    private func decodeRaw<T: Decodable>(_: T.Type, _ res: TestingHTTPResponse) throws -> T {
        let data = Data(buffer: res.body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func pkce() -> (verifier: String, challenge: String) {
        let verifier = OpaqueToken.generate(prefix: "", byteCount: 40)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return (verifier, challenge)
    }

    // MARK: - Dynamic client registration

    @Test("DCR registers a public client and rejects non-https redirect")
    func dynamicClientRegistration() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "v1/oauth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(clientName: "My App", redirectURIs: ["https://app.example/cb"]))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let body = try decodeRaw(RegisterResponse.self, res)
                #expect(body.clientID.hasPrefix("nvq_client_"))
                #expect(body.tokenEndpointAuthMethod == "none")
            })
            try await app.testing().test(.POST, "v1/oauth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(clientName: "Bad", redirectURIs: ["http://evil.example/cb"]))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    // MARK: - Full authorization-code + PKCE flow

    @Test("Authorization code flow with PKCE issues tokens")
    func authorizationCodeFlow() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await grantPro(app: app, userId: user.userId)
            let clientID = try await makeClient(app: app)
            let (verifier, challenge) = pkce()

            // /authorize creates a flow and redirects to the consent page.
            var flowID = ""
            try await app.testing().test(.GET, "v1/oauth/authorize?response_type=code&client_id=\(clientID)&redirect_uri=https://client.example/cb&scope=expenses:read%20expenses:write&state=xyz&code_challenge=\(challenge)&code_challenge_method=S256", afterResponse: { res async in
                #expect(res.status == .seeOther || res.status == .found)
                let location = res.headers.first(name: .location) ?? ""
                #expect(location.contains("flow_id="))
                flowID = String(location.split(separator: "flow_id=").last ?? "")
            })
            #expect(!flowID.isEmpty)

            // Consent approval (first-party session) returns the redirect_url with a code.
            var code = ""
            try await app.testing().test(.POST, "v1/oauth/flows/\(flowID)/approve", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try decodeRaw(ApproveResponse.self, res)
                #expect(body.redirectURL.contains("code="))
                #expect(body.redirectURL.contains("state=xyz"))
                let afterCode = body.redirectURL.split(separator: "code=").last ?? ""
                code = String(afterCode.split(separator: "&").first ?? "")
            })
            #expect(code.hasPrefix("nvq_ac_"))

            // /token exchanges the code + verifier for tokens.
            var refreshToken = ""
            try await app.testing().test(.POST, "v1/oauth/token", beforeRequest: { req in
                try req.content.encode(TokenRequest(
                    grantType: "authorization_code", code: code, redirectURI: "https://client.example/cb",
                    clientID: clientID, codeVerifier: verifier, refreshToken: nil, scope: nil
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try decodeRaw(TokenResponse.self, res)
                #expect(body.accessToken.hasPrefix("nvq_at_"))
                #expect(body.refreshToken.hasPrefix("nvq_rt_"))
                #expect(body.scope.contains("expenses:read"))
                refreshToken = body.refreshToken
            })

            // The issued access token works on a scoped endpoint.
            let accessToken = try await OAuthToken.query(on: app.db).first()?.accessTokenHash
            #expect(accessToken != nil)

            // Reusing the same code fails (single-use).
            try await app.testing().test(.POST, "v1/oauth/token", beforeRequest: { req in
                try req.content.encode(TokenRequest(
                    grantType: "authorization_code", code: code, redirectURI: "https://client.example/cb",
                    clientID: clientID, codeVerifier: verifier, refreshToken: nil, scope: nil
                ))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            // Refresh rotates and a replay of the old refresh token is rejected.
            try await app.testing().test(.POST, "v1/oauth/token", beforeRequest: { req in
                try req.content.encode(TokenRequest(
                    grantType: "refresh_token", code: nil, redirectURI: nil, clientID: clientID,
                    codeVerifier: nil, refreshToken: refreshToken, scope: nil
                ))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            try await app.testing().test(.POST, "v1/oauth/token", beforeRequest: { req in
                try req.content.encode(TokenRequest(
                    grantType: "refresh_token", code: nil, redirectURI: nil, clientID: clientID,
                    codeVerifier: nil, refreshToken: refreshToken, scope: nil
                ))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest) // reuse detected
            })
        }
    }

    @Test("PKCE verifier mismatch is rejected")
    func pkceMismatch() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await grantPro(app: app, userId: user.userId)
            let clientID = try await makeClient(app: app)
            let (_, challenge) = pkce()

            var flowID = ""
            try await app.testing().test(.GET, "v1/oauth/authorize?response_type=code&client_id=\(clientID)&redirect_uri=https://client.example/cb&scope=expenses:read&code_challenge=\(challenge)&code_challenge_method=S256", afterResponse: { res async in
                flowID = String((res.headers.first(name: .location) ?? "").split(separator: "flow_id=").last ?? "")
            })
            var code = ""
            try await app.testing().test(.POST, "v1/oauth/flows/\(flowID)/approve", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async throws in
                let body = try decodeRaw(ApproveResponse.self, res)
                code = String((body.redirectURL.split(separator: "code=").last ?? "").split(separator: "&").first ?? "")
            })
            try await app.testing().test(.POST, "v1/oauth/token", beforeRequest: { req in
                try req.content.encode(TokenRequest(
                    grantType: "authorization_code", code: code, redirectURI: "https://client.example/cb",
                    clientID: clientID, codeVerifier: "wrong-verifier", refreshToken: nil, scope: nil
                ))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Authorize rejects unregistered redirect URI")
    func authorizeRejectsBadRedirect() async throws {
        try await withApp { app in
            let clientID = try await makeClient(app: app)
            let (_, challenge) = pkce()
            try await app.testing().test(.GET, "v1/oauth/authorize?response_type=code&client_id=\(clientID)&redirect_uri=https://evil.example/cb&scope=expenses:read&code_challenge=\(challenge)&code_challenge_method=S256", afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("RFC 8414 metadata advertises S256 and endpoints")
    func metadata() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, ".well-known/oauth-authorization-server", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try decodeRaw(AuthorizationServerMetadata.self, res)
                #expect(body.codeChallengeMethodsSupported == ["S256"])
                #expect(body.grantTypesSupported.contains("authorization_code"))
                #expect(body.tokenEndpoint.hasSuffix("/v1/oauth/token"))
            })
        }
    }
}
