@testable import StockPlanBackend
import Fluent
import Foundation
import struct StockPlanShared.BillingContextResponse
import struct StockPlanShared.BillingUpgradeRequiredResponse
import Testing
import VaporTesting

@Suite("Billing Tests", .serialized)
struct BillingTests {
    private let secret = "test-billing-secret"

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            setenv("REVENUECAT_WEBHOOK_SECRET", secret, 1)
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

    private func registerUser(on app: Application, identifier: String) async throws -> AuthResponse {
        let usernameSuffix = String(identifier.filter { $0.isLetter || $0.isNumber || $0 == "_" }.prefix(18))
        let request = AuthRegisterRequest(
            username: "billing_\(usernameSuffix)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "billing+\(identifier)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
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

    private func makePayload(
        type: String,
        eventId: String,
        appUserId: String,
        productId: String = "com.app.premium_yearly",
        expirationAtMs: Int64? = nil,
        gracePeriodMs: Int64? = nil
    ) -> String {
        var fields = """
            "id": "\(eventId)",
            "type": "\(type)",
            "app_user_id": "\(appUserId)",
            "product_id": "\(productId)"
            """
        if let ms = expirationAtMs { fields += ",\n\"expiration_at_ms\": \(ms)" }
        if let ms = gracePeriodMs { fields += ",\n\"grace_period_expires_date_ms\": \(ms)" }
        return "{\"event\": {\(fields)}}"
    }

    private func post(
        _ payload: String,
        authorization: String?,
        on app: Application
    ) async throws -> HTTPStatus {
        var status: HTTPStatus = .internalServerError
        try await app.testing().test(.POST, "webhooks/revenuecat", beforeRequest: { req in
            req.headers.contentType = .json
            if let auth = authorization {
                req.headers.replaceOrAdd(name: .authorization, value: auth)
            }
            req.body = .init(string: payload)
        }, afterResponse: { res async throws in
            status = res.status
        })
        return status
    }

    private func grantPremium(userId: UUID, on app: Application) async throws {
        let entitlement = Entitlement(userId: userId, level: "premium")
        try await entitlement.save(on: app.db)
    }

    private func createStock(
        symbol: String,
        token: String,
        on app: Application
    ) async throws -> (HTTPStatus, String) {
        var status: HTTPStatus = .internalServerError
        var body = ""
        try await app.testing().test(.POST, "v1/stocks", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(
                StockRequest(
                    symbol: symbol,
                    shares: 1,
                    buyPrice: 100,
                    buyDate: "2026-01-01",
                    notes: nil
                )
            )
        }, afterResponse: { res async in
            status = res.status
            body = res.body.string
        })
        return (status, body)
    }

    private func commitCsv(
        token: String,
        csv: String,
        on app: Application
    ) async throws -> (HTTPStatus, String) {
        var status: HTTPStatus = .internalServerError
        var body = ""
        try await app.testing().test(.POST, "v1/brokers/import/csv/commit?provider=ibkr", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            req.headers.contentType = .plainText
            req.body = .init(string: csv)
        }, afterResponse: { res async in
            status = res.status
            body = res.body.string
        })
        return (status, body)
    }

    private func get(
        _ path: String,
        token: String,
        on app: Application
    ) async throws -> (HTTPStatus, String) {
        var status: HTTPStatus = .internalServerError
        var body = ""
        try await app.testing().test(.GET, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async in
            status = res.status
            body = res.body.string
        })
        return (status, body)
    }

    private func getBillingContext(
        token: String,
        on app: Application
    ) async throws -> (HTTPStatus, BillingContextResponse?, String) {
        var status: HTTPStatus = .internalServerError
        var context: BillingContextResponse?
        var body = ""
        try await app.testing().test(.GET, "v1/billing/me", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            status = res.status
            body = res.body.string
            if res.status == .ok {
                context = try res.content.decode(BillingContextResponse.self)
            }
        })
        return (status, context, body)
    }

    // MARK: - Auth tests

    @Test("Missing Authorization header returns 401")
    func missingAuthReturns401() async throws {
        try await withApp { app in
            let status = try await post(makePayload(type: "INITIAL_PURCHASE", eventId: UUID().uuidString, appUserId: UUID().uuidString), authorization: nil, on: app)
            #expect(status == .unauthorized)
        }
    }

    @Test("Wrong Authorization header returns 401")
    func wrongAuthReturns401() async throws {
        try await withApp { app in
            let status = try await post(makePayload(type: "INITIAL_PURCHASE", eventId: UUID().uuidString, appUserId: UUID().uuidString), authorization: "wrong-secret", on: app)
            #expect(status == .unauthorized)
        }
    }

    // MARK: - Event tests

    @Test("INITIAL_PURCHASE creates active subscription and premium entitlement")
    func initialPurchase() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "purchase")
            let userId = auth.userId
            let futureMs = Int64(Date().addingTimeInterval(2_592_000).timeIntervalSince1970 * 1000)
            let payload = makePayload(type: "INITIAL_PURCHASE", eventId: UUID().uuidString, appUserId: userId.uuidString, productId: "com.app.premium_monthly", expirationAtMs: futureMs)

            let status = try await post(payload, authorization: secret, on: app)
            #expect(status == .ok)

            let sub = try await Subscription.query(on: app.db).filter(\.$userId == userId).first()
            let ent = try await Entitlement.query(on: app.db).filter(\.$userId == userId).first()
            #expect(sub?.status == "active")
            #expect(sub?.plan == "premium_monthly")
            #expect(ent?.level == "premium")
        }
    }

    @Test("RENEWAL updates subscription and keeps premium entitlement")
    func renewal() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "renewal")
            let userId = auth.userId
            let futureMs = Int64(Date().addingTimeInterval(2_592_000).timeIntervalSince1970 * 1000)

            // Initial purchase first
            let purchasePayload = makePayload(type: "INITIAL_PURCHASE", eventId: UUID().uuidString, appUserId: userId.uuidString, expirationAtMs: futureMs)
            _ = try await post(purchasePayload, authorization: secret, on: app)

            // Renewal
            let renewalPayload = makePayload(type: "RENEWAL", eventId: UUID().uuidString, appUserId: userId.uuidString, expirationAtMs: futureMs)
            let status = try await post(renewalPayload, authorization: secret, on: app)
            #expect(status == .ok)

            let ent = try await Entitlement.query(on: app.db).filter(\.$userId == userId).first()
            #expect(ent?.level == "premium")
        }
    }

    @Test("CANCELLATION sets subscription cancelled, entitlement stays premium")
    func cancellation() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "cancel")
            let userId = auth.userId
            let futureMs = Int64(Date().addingTimeInterval(2_592_000).timeIntervalSince1970 * 1000)

            _ = try await post(makePayload(type: "INITIAL_PURCHASE", eventId: UUID().uuidString, appUserId: userId.uuidString, expirationAtMs: futureMs), authorization: secret, on: app)
            let status = try await post(makePayload(type: "CANCELLATION", eventId: UUID().uuidString, appUserId: userId.uuidString), authorization: secret, on: app)
            #expect(status == .ok)

            let sub = try await Subscription.query(on: app.db).filter(\.$userId == userId).first()
            let ent = try await Entitlement.query(on: app.db).filter(\.$userId == userId).first()
            #expect(sub?.status == "cancelled")
            #expect(ent?.level == "premium")
        }
    }

    @Test("EXPIRATION sets subscription expired and entitlement to free")
    func expiration() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "expire")
            let userId = auth.userId

            _ = try await post(makePayload(type: "INITIAL_PURCHASE", eventId: UUID().uuidString, appUserId: userId.uuidString), authorization: secret, on: app)
            let status = try await post(makePayload(type: "EXPIRATION", eventId: UUID().uuidString, appUserId: userId.uuidString), authorization: secret, on: app)
            #expect(status == .ok)

            let sub = try await Subscription.query(on: app.db).filter(\.$userId == userId).first()
            let ent = try await Entitlement.query(on: app.db).filter(\.$userId == userId).first()
            #expect(sub?.status == "expired")
            #expect(ent?.level == "free")
        }
    }

    @Test("REFUND sets subscription refunded and entitlement to free")
    func refund() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "refund")
            let userId = auth.userId

            _ = try await post(makePayload(type: "INITIAL_PURCHASE", eventId: UUID().uuidString, appUserId: userId.uuidString), authorization: secret, on: app)
            let status = try await post(makePayload(type: "REFUND", eventId: UUID().uuidString, appUserId: userId.uuidString), authorization: secret, on: app)
            #expect(status == .ok)

            let sub = try await Subscription.query(on: app.db).filter(\.$userId == userId).first()
            let ent = try await Entitlement.query(on: app.db).filter(\.$userId == userId).first()
            #expect(sub?.status == "refunded")
            #expect(ent?.level == "free")
        }
    }

    @Test("BILLING_ISSUE with future grace period keeps premium entitlement")
    func billingIssueWithGracePeriod() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "billing-grace")
            let userId = auth.userId
            let futureGraceMs = Int64(Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1000)

            _ = try await post(makePayload(type: "INITIAL_PURCHASE", eventId: UUID().uuidString, appUserId: userId.uuidString), authorization: secret, on: app)
            let status = try await post(makePayload(type: "BILLING_ISSUE", eventId: UUID().uuidString, appUserId: userId.uuidString, gracePeriodMs: futureGraceMs), authorization: secret, on: app)
            #expect(status == .ok)

            let sub = try await Subscription.query(on: app.db).filter(\.$userId == userId).first()
            let ent = try await Entitlement.query(on: app.db).filter(\.$userId == userId).first()
            #expect(sub?.status == "billing_issue")
            #expect(ent?.level == "premium")
        }
    }

    @Test("BILLING_ISSUE without grace period sets entitlement to free")
    func billingIssueNoGracePeriod() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "billing-nograce")
            let userId = auth.userId

            _ = try await post(makePayload(type: "INITIAL_PURCHASE", eventId: UUID().uuidString, appUserId: userId.uuidString), authorization: secret, on: app)
            let status = try await post(makePayload(type: "BILLING_ISSUE", eventId: UUID().uuidString, appUserId: userId.uuidString), authorization: secret, on: app)
            #expect(status == .ok)

            let sub = try await Subscription.query(on: app.db).filter(\.$userId == userId).first()
            let ent = try await Entitlement.query(on: app.db).filter(\.$userId == userId).first()
            #expect(sub?.status == "billing_issue")
            #expect(ent?.level == "free")
        }
    }

    @Test("Duplicate event is idempotent - only one BillingEvent row persisted")
    func duplicateEventIsIdempotent() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "idempotent")
            let userId = auth.userId
            let eventId = UUID().uuidString
            let payload = makePayload(type: "INITIAL_PURCHASE", eventId: eventId, appUserId: userId.uuidString)

            let s1 = try await post(payload, authorization: secret, on: app)
            let s2 = try await post(payload, authorization: secret, on: app)
            #expect(s1 == .ok)
            #expect(s2 == .ok)

            let count = try await BillingEvent.query(on: app.db)
                .filter(\.$providerEventId == eventId)
                .count()
            #expect(count == 1)
        }
    }

    @Test("Non-UUID app user id persists event without mutating entitlement state")
    func nonUUIDAppUserIdPersistsEventOnly() async throws {
        try await withApp { app in
            let eventId = UUID().uuidString
            let payload = makePayload(type: "INITIAL_PURCHASE", eventId: eventId, appUserId: "revenuecat-alias")

            let status = try await post(payload, authorization: secret, on: app)
            #expect(status == .ok)

            let event = try await BillingEvent.query(on: app.db)
                .filter(\.$providerEventId == eventId)
                .first()
            #expect(event?.userId == nil)
            #expect(event?.rawPayload.contains("revenuecat-alias") == true)

            let subscriptionCount = try await Subscription.query(on: app.db).count()
            let entitlementCount = try await Entitlement.query(on: app.db).count()
            #expect(subscriptionCount == 0)
            #expect(entitlementCount == 0)
        }
    }

    // MARK: - Entitlement and usage tests

    @Test("Free users are blocked when holding count exceeds the free limit")
    func freeHoldingLimitBlocks() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "free-holdings")
            let symbols = ["AAPL", "MSFT", "GOOG", "AMZN", "NVDA"]

            for symbol in symbols {
                let (status, _) = try await createStock(symbol: symbol, token: auth.token, on: app)
                #expect(status == .created)
            }

            let (status, body) = try await createStock(symbol: "TSLA", token: auth.token, on: app)
            #expect(status == .paymentRequired)
            #expect(body.contains("feature=holdings"))

            let counter = try await UsageCounter.query(on: app.db)
                .filter(\.$userId == auth.userId)
                .first()
            #expect(counter?.holdingCount == 5)
        }
    }

    @Test("Premium users can exceed the free holding limit")
    func premiumHoldingLimitBypassesFreeLimit() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "premium-holdings")
            try await grantPremium(userId: auth.userId, on: app)
            let symbols = ["AAPL", "MSFT", "GOOG", "AMZN", "NVDA", "TSLA"]

            for symbol in symbols {
                let (status, _) = try await createStock(symbol: symbol, token: auth.token, on: app)
                #expect(status == .created)
            }

            let count = try await Stock.query(on: app.db)
                .filter(\.$userId == auth.userId)
                .count()
            #expect(count == 6)
        }
    }

    @Test("Free users are blocked after the monthly CSV import limit")
    func freeCsvImportLimitBlocksSecondImport() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "free-csv")

            let first = try await commitCsv(
                token: auth.token,
                csv: "symbol,quantity,average_cost,buy_date\nAAPL,1,100,2026-01-01\n",
                on: app
            )
            #expect(first.0 == .ok)

            let second = try await commitCsv(
                token: auth.token,
                csv: "symbol,quantity,average_cost,buy_date\nMSFT,1,100,2026-01-01\n",
                on: app
            )
            #expect(second.0 == .paymentRequired)
            #expect(second.1.contains("feature=csv_imports"))

            let counter = try await UsageCounter.query(on: app.db)
                .filter(\.$userId == auth.userId)
                .first()
            #expect(counter?.csvImportCount == 1)
        }
    }

    @Test("Free users are blocked from advanced stock insights")
    func freeAdvancedResearchRequiresPremium() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "free-research")

            let (status, body) = try await get("v1/stocks/AAPL/insights", token: auth.token, on: app)
            #expect(status == .paymentRequired)
            #expect(body.contains("feature=advanced_research"))
            #expect(body.contains("required=premium"))
        }
    }

    @Test("Free users are blocked from peer comparison")
    func freePeerComparisonRequiresPremium() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "free-compare")

            let (status, body) = try await get("v1/market/compare?symbols=AAPL,MSFT", token: auth.token, on: app)
            #expect(status == .paymentRequired)
            #expect(body.contains("feature=peer_comparison"))
            #expect(body.contains("required=premium"))
        }
    }

    @Test("Free users are blocked from earnings text")
    func freeEarningsTextRequiresPremium() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "free-earnings")

            let (status, body) = try await get("v1/market/earnings/AAPL", token: auth.token, on: app)
            #expect(status == .paymentRequired)
            #expect(body.contains("feature=earnings_text"))
            #expect(body.contains("required=premium"))
        }
    }

    // MARK: - Billing context tests

    @Test("Billing context returns free plan rules and usage")
    func billingContextForFreeUser() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "context-free")
            _ = try await createStock(symbol: "AAPL", token: auth.token, on: app)

            let (status, context, _) = try await getBillingContext(token: auth.token, on: app)
            #expect(status == .ok)
            let body = try #require(context)
            #expect(body.plan == "free")
            #expect(body.entitlementLevel == "free")
            #expect(body.isPremium == false)
            #expect(body.subscription == nil)

            let holdings = try #require(body.usage.first { $0.key == "holdings" })
            #expect(holdings.used == 1)
            #expect(holdings.limit == 5)
            #expect(holdings.remaining == 4)

            let research = try #require(body.features.first { $0.key == "advanced_research" })
            #expect(research.available == false)
            #expect(research.requiredPlan == "premium")
        }
    }

    @Test("Billing context returns premium yearly subscription state")
    func billingContextForPremiumYearlyUser() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "context-yearly")
            let futureMs = Int64(Date().addingTimeInterval(31_536_000).timeIntervalSince1970 * 1000)
            let payload = makePayload(
                type: "INITIAL_PURCHASE",
                eventId: UUID().uuidString,
                appUserId: auth.userId.uuidString,
                productId: "com.app.premium_yearly",
                expirationAtMs: futureMs
            )
            #expect(try await post(payload, authorization: secret, on: app) == .ok)

            let (status, context, _) = try await getBillingContext(token: auth.token, on: app)
            #expect(status == .ok)
            let body = try #require(context)
            #expect(body.plan == "premium_yearly")
            #expect(body.entitlementLevel == "premium")
            #expect(body.isPremium == true)
            #expect(body.subscription?.status == "active")
            #expect(body.subscription?.plan == "premium_yearly")
            #expect(body.subscription?.renewsOrExpiresAt != nil)
            #expect(body.features.allSatisfy { $0.available })
            #expect(body.usage.first { $0.key == "holdings" }?.limit == nil)
        }
    }

    @Test("Billing context reports cancelled but still active state")
    func billingContextForCancelledButActiveUser() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "context-cancel")
            let futureMs = Int64(Date().addingTimeInterval(2_592_000).timeIntervalSince1970 * 1000)
            #expect(try await post(
                makePayload(
                    type: "INITIAL_PURCHASE",
                    eventId: UUID().uuidString,
                    appUserId: auth.userId.uuidString,
                    expirationAtMs: futureMs
                ),
                authorization: secret,
                on: app
            ) == .ok)
            #expect(try await post(
                makePayload(
                    type: "CANCELLATION",
                    eventId: UUID().uuidString,
                    appUserId: auth.userId.uuidString,
                    expirationAtMs: futureMs
                ),
                authorization: secret,
                on: app
            ) == .ok)

            let (status, context, _) = try await getBillingContext(token: auth.token, on: app)
            #expect(status == .ok)
            let body = try #require(context)
            #expect(body.isPremium == true)
            #expect(body.subscription?.status == "cancelled")
            #expect(body.subscription?.isCancelledButActive == true)
            #expect(body.subscription?.periodEndsAt != nil)
        }
    }

    @Test("Premium gate failures return stable JSON error envelope")
    func premiumGateReturnsBillingErrorEnvelope() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "context-error")
            var error: BillingUpgradeRequiredResponse?
            try await app.testing().test(.GET, "v1/stocks/AAPL/insights", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                error = try res.content.decode(BillingUpgradeRequiredResponse.self)
            })

            let body = try #require(error)
            #expect(body.success == false)
            #expect(body.code == "upgrade_required")
            #expect(body.feature == "advanced_research")
            #expect(body.plan == "free")
            #expect(body.requiredPlan == "premium")
        }
    }
}
