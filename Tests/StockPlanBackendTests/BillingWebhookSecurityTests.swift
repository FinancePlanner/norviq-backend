import Foundation
@testable import StockPlanBackend
import Testing
import Vapor

@Suite("Billing Webhook Security", .serialized)
struct BillingWebhookSecurityTests {
    // MARK: constant-time secret comparison

    @Test
    func constantTimeEqualsMatchesIdenticalSecrets() {
        #expect(RevenueCatWebhookController.constantTimeEquals("super-secret", "super-secret"))
    }

    @Test
    func constantTimeEqualsRejectsDifferentSecrets() {
        #expect(!RevenueCatWebhookController.constantTimeEquals("super-secret", "super-secre7"))
    }

    @Test
    func constantTimeEqualsRejectsDifferentLengths() {
        #expect(!RevenueCatWebhookController.constantTimeEquals("secret", "secret-extra"))
        #expect(!RevenueCatWebhookController.constantTimeEquals("", "secret"))
    }

    @Test
    func constantTimeEqualsMatchesEmptyStrings() {
        #expect(RevenueCatWebhookController.constantTimeEquals("", ""))
    }

    // MARK: startup secret validation

    @Test
    func productionBootFailsWhenWebhookSecretMissing() async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.production)
            // Unset AFTER make: Application bootstrap loads .env files into the process env.
            unsetenv("REVENUECAT_WEBHOOK_SECRET")
            unsetenv("REVENUECAT_API_KEY")
            #expect(throws: (any Error).self) {
                try validateBillingSecrets(app)
            }
            try await app.asyncShutdown()
        }
    }

    @Test
    func productionBootSucceedsWhenSecretsPresent() async throws {
        try await DatabaseTestLock.withLock {
            setenv("REVENUECAT_WEBHOOK_SECRET", "present", 1)
            setenv("REVENUECAT_API_KEY", "present", 1)
            let app = try await Application.make(.production)
            do {
                try validateBillingSecrets(app)
            } catch {
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
            unsetenv("REVENUECAT_WEBHOOK_SECRET")
            unsetenv("REVENUECAT_API_KEY")
        }
    }

    @Test
    func developmentBootDoesNotThrowWhenSecretsMissing() async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.development)
            // Unset AFTER make: Application bootstrap loads .env files into the process env.
            unsetenv("REVENUECAT_WEBHOOK_SECRET")
            unsetenv("REVENUECAT_API_KEY")
            do {
                try validateBillingSecrets(app)
            } catch {
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }
}
