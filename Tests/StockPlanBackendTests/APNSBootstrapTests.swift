@testable import StockPlanBackend
import Testing
import Vapor

@Suite("APNS Bootstrap Tests", .serialized)
struct APNSBootstrapTests {
    @Test("Configured APNS validates malformed private key")
    func configuredAPNSValidatesMalformedPrivateKey() async throws {
        try await withAPNSEnvironment(privateKey: "not-a-valid-pem") {
            let app = try await Application.make(.development)

            let config = try #require(APNSBootstrapConfiguration.fromEnvironment(app: app))
            #expect(throws: (any Error).self) {
                try config.validatePrivateKey()
            }
            try await app.asyncShutdown()
        }
    }

    @Test("Development ignores malformed APNS private key")
    func developmentIgnoresMalformedAPNSPrivateKey() async throws {
        try await withAPNSEnvironment(privateKey: "not-a-valid-pem") {
            let app = try await Application.make(.development)

            #expect(throws: Never.self) {
                try configureAPNS(app)
            }
            try await app.asyncShutdown()
        }
    }

    @Test("Production rejects malformed APNS private key")
    func productionRejectsMalformedAPNSPrivateKey() async throws {
        try await withAPNSEnvironment(privateKey: "not-a-valid-pem") {
            let app = try await Application.make(.production)

            #expect(throws: (any Error).self) {
                try configureAPNS(app)
            }
            try await app.asyncShutdown()
        }
    }

    private func withAPNSEnvironment(
        privateKey: String,
        run: () async throws -> Void
    ) async throws {
        setenv("APNS_TEAM_ID", "TEAMID1234", 1)
        setenv("APNS_KEY_ID", "KEYID12345", 1)
        setenv("APNS_TOPIC", "com.example.StockPlan", 1)
        setenv("APNS_PRIVATE_KEY_P8", privateKey, 1)
        defer {
            unsetenv("APNS_TEAM_ID")
            unsetenv("APNS_KEY_ID")
            unsetenv("APNS_TOPIC")
            unsetenv("APNS_PRIVATE_KEY_P8")
        }

        try await run()
    }
}
