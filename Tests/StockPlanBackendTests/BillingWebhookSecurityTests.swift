import Crypto
import Fluent
import FluentPostgresDriver
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
    func productionBootFailsWhenWebhookSecretAndHMACSecretBothMissing() async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.production)
            // Unset AFTER make: Application bootstrap loads .env files into the process env.
            unsetenv("REVENUECAT_WEBHOOK_SECRET")
            unsetenv("REVENUECAT_HMAC_SECRET")
            unsetenv("REVENUECAT_API_KEY")
            #expect(throws: (any Error).self) {
                try validateBillingSecrets(app)
            }
            try await app.asyncShutdown()
        }
    }

    @Test
    func productionBootSucceedsWhenWebhookSecretPresent() async throws {
        try await DatabaseTestLock.withLock {
            setenv("REVENUECAT_WEBHOOK_SECRET", "present", 1)
            unsetenv("REVENUECAT_HMAC_SECRET")
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
    func productionBootSucceedsWhenHMACSecretPresent() async throws {
        try await DatabaseTestLock.withLock {
            unsetenv("REVENUECAT_WEBHOOK_SECRET")
            setenv("REVENUECAT_HMAC_SECRET", "present_hmac", 1)
            setenv("REVENUECAT_API_KEY", "present", 1)
            let app = try await Application.make(.production)
            do {
                try validateBillingSecrets(app)
            } catch {
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
            unsetenv("REVENUECAT_HMAC_SECRET")
            unsetenv("REVENUECAT_API_KEY")
        }
    }

    @Test
    func developmentBootDoesNotThrowWhenSecretsMissing() async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.development)
            // Unset AFTER make: Application bootstrap loads .env files into the process env.
            unsetenv("REVENUECAT_WEBHOOK_SECRET")
            unsetenv("REVENUECAT_HMAC_SECRET")
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

    // MARK: Webhook HMAC signature validation

    @Test
    func webhookHMACValidationSucceedsWithValidSignature() async throws {
        try await DatabaseTestLock.withLock {
            let hmacSecret = "test-hmac-secret-12345"
            setenv("REVENUECAT_HMAC_SECRET", hmacSecret, 1)
            setenv("REVENUECAT_API_KEY", "present", 1)
            let app = try await Application.make(.testing)
            app.databases.use(
                .postgres(configuration: .init(
                    hostname: "localhost",
                    port: 5432,
                    username: "dummy",
                    password: "dummy",
                    database: "dummy"
                )),
                as: .psql
            )
            app.billingService = MockBillingService()
            try app.register(collection: RevenueCatWebhookController())

            let payload = "{\"event\": {\"id\": \"test_event\", \"type\": \"INITIAL_PURCHASE\", \"app_user_id\": \"test_user\", \"product_id\": \"pro_annual\"}}"
            let signatureHeader = revenueCatSignatureHeader(payload: payload, secret: hmacSecret)

            var status: HTTPStatus = .internalServerError
            try await app.testing().test(.POST, "webhooks/revenuecat", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: "X-RevenueCat-Webhook-Signature", value: signatureHeader)
                req.body = .init(string: payload)
            }, afterResponse: { res async throws in
                status = res.status
            })

            #expect(status == .ok)

            try await app.asyncShutdown()
            unsetenv("REVENUECAT_HMAC_SECRET")
            unsetenv("REVENUECAT_API_KEY")
        }
    }

    @Test
    func webhookHMACValidationFailsWithInvalidSignature() async throws {
        try await DatabaseTestLock.withLock {
            let hmacSecret = "test-hmac-secret-12345"
            setenv("REVENUECAT_HMAC_SECRET", hmacSecret, 1)
            setenv("REVENUECAT_API_KEY", "present", 1)
            let app = try await Application.make(.testing)
            app.databases.use(
                .postgres(configuration: .init(
                    hostname: "localhost",
                    port: 5432,
                    username: "dummy",
                    password: "dummy",
                    database: "dummy"
                )),
                as: .psql
            )
            app.billingService = MockBillingService()
            try app.register(collection: RevenueCatWebhookController())

            let payload = "{\"event\": {\"id\": \"test_event\"}}"

            var status: HTTPStatus = .internalServerError
            try await app.testing().test(.POST, "webhooks/revenuecat", beforeRequest: { req in
                req.headers.contentType = .json
                let timestamp = Int64(Date().timeIntervalSince1970)
                req.headers.replaceOrAdd(name: "X-RevenueCat-Webhook-Signature", value: "t=\(timestamp),v1=invalid-signature")
                req.body = .init(string: payload)
            }, afterResponse: { res async throws in
                status = res.status
            })

            #expect(status == .unauthorized)

            try await app.asyncShutdown()
            unsetenv("REVENUECAT_HMAC_SECRET")
            unsetenv("REVENUECAT_API_KEY")
        }
    }

    @Test
    func webhookHMACValidationFailsWithStaleSignatureTimestamp() async throws {
        try await DatabaseTestLock.withLock {
            let hmacSecret = "test-hmac-secret-12345"
            setenv("REVENUECAT_HMAC_SECRET", hmacSecret, 1)
            setenv("REVENUECAT_API_KEY", "present", 1)
            let app = try await Application.make(.testing)
            app.databases.use(
                .postgres(configuration: .init(
                    hostname: "localhost",
                    port: 5432,
                    username: "dummy",
                    password: "dummy",
                    database: "dummy"
                )),
                as: .psql
            )
            app.billingService = MockBillingService()
            try app.register(collection: RevenueCatWebhookController())

            let payload = "{\"event\": {\"id\": \"test_event\"}}"
            let signatureHeader = revenueCatSignatureHeader(payload: payload, secret: hmacSecret, timestamp: 1_700_000_000)

            var status: HTTPStatus = .internalServerError
            try await app.testing().test(.POST, "webhooks/revenuecat", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: "X-RevenueCat-Webhook-Signature", value: signatureHeader)
                req.body = .init(string: payload)
            }, afterResponse: { res async throws in
                status = res.status
            })

            #expect(status == .unauthorized)

            try await app.asyncShutdown()
            unsetenv("REVENUECAT_HMAC_SECRET")
            unsetenv("REVENUECAT_API_KEY")
        }
    }

    @Test
    func webhookHMACValidationFailsWithMissingSignature() async throws {
        try await DatabaseTestLock.withLock {
            let hmacSecret = "test-hmac-secret-12345"
            setenv("REVENUECAT_HMAC_SECRET", hmacSecret, 1)
            setenv("REVENUECAT_API_KEY", "present", 1)
            let app = try await Application.make(.testing)
            app.databases.use(
                .postgres(configuration: .init(
                    hostname: "localhost",
                    port: 5432,
                    username: "dummy",
                    password: "dummy",
                    database: "dummy"
                )),
                as: .psql
            )
            app.billingService = MockBillingService()
            try app.register(collection: RevenueCatWebhookController())

            let payload = "{\"event\": {\"id\": \"test_event\"}}"

            var status: HTTPStatus = .internalServerError
            try await app.testing().test(.POST, "webhooks/revenuecat", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: payload)
            }, afterResponse: { res async throws in
                status = res.status
            })

            #expect(status == .unauthorized)

            try await app.asyncShutdown()
            unsetenv("REVENUECAT_HMAC_SECRET")
            unsetenv("REVENUECAT_API_KEY")
        }
    }

    @Test
    func webhookFallbackToLegacyAuthSucceeds() async throws {
        try await DatabaseTestLock.withLock {
            let webhookSecret = "test-webhook-secret-12345"
            unsetenv("REVENUECAT_HMAC_SECRET")
            setenv("REVENUECAT_WEBHOOK_SECRET", webhookSecret, 1)
            setenv("REVENUECAT_API_KEY", "present", 1)
            let app = try await Application.make(.testing)
            app.databases.use(
                .postgres(configuration: .init(
                    hostname: "localhost",
                    port: 5432,
                    username: "dummy",
                    password: "dummy",
                    database: "dummy"
                )),
                as: .psql
            )
            app.billingService = MockBillingService()
            try app.register(collection: RevenueCatWebhookController())

            let payload = "{\"event\": {\"id\": \"test_event\", \"type\": \"INITIAL_PURCHASE\", \"app_user_id\": \"test_user\", \"product_id\": \"pro_annual\"}}"

            var status: HTTPStatus = .internalServerError
            try await app.testing().test(.POST, "webhooks/revenuecat", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .authorization, value: webhookSecret)
                req.body = .init(string: payload)
            }, afterResponse: { res async throws in
                status = res.status
            })

            #expect(status == .ok)

            try await app.asyncShutdown()
            unsetenv("REVENUECAT_WEBHOOK_SECRET")
            unsetenv("REVENUECAT_API_KEY")
        }
    }
}

private struct MockBillingService: BillingService {
    func process(event _: RevenueCatWebhookEvent, rawPayload _: String, on _: any Database) async throws {}
}

private func revenueCatSignatureHeader(
    payload: String,
    secret: String,
    timestamp: Int64 = Int64(Date().timeIntervalSince1970)
) -> String {
    let signedPayload = "\(timestamp).\(payload)"
    let key = SymmetricKey(data: Data(secret.utf8))
    let hmac = HMAC<SHA256>.authenticationCode(for: Data(signedPayload.utf8), using: key)
    let hex = Data(hmac).map { String(format: "%02x", $0) }.joined()
    return "t=\(timestamp),v1=\(hex)"
}
