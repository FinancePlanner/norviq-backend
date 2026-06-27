@testable import StockPlanBackend
import Testing
import Vapor

struct IBKROAuthClientTests {
    @Test("IBKR OAuth client builds authorization URL with backend callback")
    func ibkrOAuthClientBuildsAuthorizationURLWithBackendCallback() throws {
        let client = try IBKROAuthClient(config: IBKROAuthConfiguration(
            clientID: "stockplan-client",
            keyID: nil,
            privateKeyPEM: nil,
            authorizationURL: #require(URL(string: "https://oauth2.ibkr.example/authorize")),
            tokenURL: URI(string: "https://oauth2.ibkr.example/token"),
            apiBaseURL: "https://api.ibkr.example/v1/api",
            scope: "portfolio.read"
        ))

        let url = try client.makeAuthorizationURL(
            state: "state-123",
            redirectURI: "https://api.stockplan.test/v1/auth/brokers/ibkr/callback"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(components.scheme == "https")
        #expect(components.host == "oauth2.ibkr.example")
        #expect(components.path == "/authorize")
        #expect(query["response_type"] == "code")
        #expect(query["client_id"] == "stockplan-client")
        #expect(query["redirect_uri"] == "https://api.stockplan.test/v1/auth/brokers/ibkr/callback")
        #expect(query["scope"] == "portfolio.read")
        #expect(query["state"] == "state-123")
    }

    @Test("IBKR connect mode defaults to OAuth when OAuth config is present")
    func ibkrConnectModeDefaultsToOAuthWhenConfigIsPresent() throws {
        unsetenv("IBKR_CONNECT_MODE")
        #expect(try IBKRConnectMode.fromEnvironment(hasOAuthConfiguration: true) == .oauth2)
        #expect(try IBKRConnectMode.fromEnvironment(hasOAuthConfiguration: false) == .gateway)
    }
}
