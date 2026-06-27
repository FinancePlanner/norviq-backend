import Fluent
import Foundation
import StockPlanShared
import Vapor

struct BillingController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let billing = protected.grouped("billing")

        billing.get("me", use: me)
        billing.post("restore", use: restore)
        billing.post("coupon", "redeem", use: redeemCoupon)
    }

    @Sendable
    func me(req: Request) async throws -> BillingContextResponse {
        let session = try req.auth.require(SessionToken.self)
        return try await req.billingContextService.context(userId: session.userId, on: req.db)
    }

    @Sendable
    func restore(req: Request) async throws -> BillingContextResponse {
        let session = try req.auth.require(SessionToken.self)
        let apiKey = try revenueCatAPIKey()
        let subscriber = try await fetchRevenueCatSubscriber(userId: session.userId, apiKey: apiKey, req: req)
        try await syncRevenueCatSubscriber(subscriber, userId: session.userId, on: req.db)
        return try await req.billingContextService.context(userId: session.userId, on: req.db)
    }

    @Sendable
    func redeemCoupon(req: Request) async throws -> CouponRedemptionResponse {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(CouponCodeRequest.self)
        guard let user = try await User.find(session.userId, on: req.db) else {
            throw Abort(.notFound, reason: "User not found.")
        }
        let redemption = try await req.application.couponService.redeemCoupon(
            code: payload.code,
            user: user,
            db: req.db
        )
        let context = try await req.billingContextService.context(userId: session.userId, on: req.db)
        return redemption.withBillingContext(context)
    }
}

private extension BillingController {
    struct RevenueCatSubscriberResponse: Decodable {
        let subscriber: RevenueCatSubscriber
    }

    struct RevenueCatSubscriber: Decodable {
        let entitlements: [String: RevenueCatEntitlement]
        let subscriptions: [String: RevenueCatSubscription]
    }

    struct RevenueCatEntitlement: Decodable {
        let expiresDate: String?
        let purchaseDate: String?
        let productIdentifier: String?

        enum CodingKeys: String, CodingKey {
            case expiresDate = "expires_date"
            case purchaseDate = "purchase_date"
            case productIdentifier = "product_identifier"
        }
    }

    struct RevenueCatSubscription: Decodable {
        let expiresDate: String?
        let purchaseDate: String?
        let originalPurchaseDate: String?
        let periodType: String?
        let store: String?
        let unsubscribeDetectedAt: String?
        let billingIssuesDetectedAt: String?
        let gracePeriodExpiresDate: String?

        enum CodingKeys: String, CodingKey {
            case expiresDate = "expires_date"
            case purchaseDate = "purchase_date"
            case originalPurchaseDate = "original_purchase_date"
            case periodType = "period_type"
            case store
            case unsubscribeDetectedAt = "unsubscribe_detected_at"
            case billingIssuesDetectedAt = "billing_issues_detected_at"
            case gracePeriodExpiresDate = "grace_period_expires_date"
        }
    }

    func revenueCatAPIKey() throws -> String {
        let value = Environment.get("REVENUECAT_API_KEY")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "REVENUECAT_API_KEY is not configured.")
        }
        return value
    }

    func fetchRevenueCatSubscriber(
        userId: UUID,
        apiKey: String,
        req: Request
    ) async throws -> RevenueCatSubscriber {
        let encodedUserId = userId.uuidString.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userId.uuidString
        let response = try await req.client.get("https://api.revenuecat.com/v1/subscribers/\(encodedUserId)") { clientRequest in
            clientRequest.headers.bearerAuthorization = .init(token: apiKey)
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            clientRequest.headers.contentType = .json
        }

        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "RevenueCat subscriber lookup failed with status \(response.status.code).")
        }

        do {
            return try response.content.decode(RevenueCatSubscriberResponse.self).subscriber
        } catch {
            throw Abort(.badGateway, reason: "RevenueCat subscriber response was invalid.")
        }
    }

    func syncRevenueCatSubscriber(
        _ subscriber: RevenueCatSubscriber,
        userId: UUID,
        on db: any Database
    ) async throws {
        let proEntitlement = subscriber.entitlements["pro"]
        let productId = proEntitlement?.productIdentifier
            ?? subscriber.subscriptions.keys.sorted(by: preferredProductSort).first
            ?? "unknown"
        let subscriptionInfo = subscriber.subscriptions[productId]
        let periodEndsAt = parseRevenueCatDate(proEntitlement?.expiresDate ?? subscriptionInfo?.expiresDate)
        let purchaseDate = parseRevenueCatDate(proEntitlement?.purchaseDate ?? subscriptionInfo?.purchaseDate ?? subscriptionInfo?.originalPurchaseDate)
        let graceEndsAt = parseRevenueCatDate(subscriptionInfo?.gracePeriodExpiresDate)
        let now = Date()
        let isActive = periodEndsAt.map { $0 > now } ?? false
        let isInGrace = graceEndsAt.map { $0 > now } ?? false
        let hasBillingIssue = subscriptionInfo?.billingIssuesDetectedAt != nil
        let isCancelled = subscriptionInfo?.unsubscribeDetectedAt != nil

        let status: String
        let entitlementLevel: String
        if isActive {
            status = isCancelled ? "cancelled" : "active"
            entitlementLevel = "pro"
        } else if hasBillingIssue && isInGrace {
            status = "billing_issue"
            entitlementLevel = "pro"
        } else if hasBillingIssue {
            status = "billing_issue"
            entitlementLevel = "free"
        } else {
            status = "expired"
            entitlementLevel = "free"
        }

        let subscription = try await Subscription.query(on: db)
            .filter(\.$provider == "revenuecat")
            .filter(\.$providerOriginalTransactionId == "\(userId.uuidString):\(productId)")
            .first()
            ?? Subscription(
                userId: userId,
                provider: "revenuecat",
                providerCustomerId: userId.uuidString,
                providerOriginalTransactionId: "\(userId.uuidString):\(productId)",
                productId: productId,
                plan: plan(for: productId),
                status: status
            )

        subscription.userId = userId
        subscription.providerCustomerId = userId.uuidString
        subscription.productId = productId
        subscription.plan = plan(for: productId)
        subscription.status = status
        subscription.periodStartedAt = purchaseDate ?? subscription.periodStartedAt
        subscription.periodEndsAt = periodEndsAt
        subscription.trialEndsAt = subscriptionInfo?.periodType?.uppercased() == "TRIAL" ? periodEndsAt : subscription.trialEndsAt
        subscription.gracePeriodEndsAt = graceEndsAt
        subscription.cancelledAt = parseRevenueCatDate(subscriptionInfo?.unsubscribeDetectedAt)
        try await subscription.save(on: db)

        let entitlement = try await Entitlement.query(on: db)
            .filter(\.$userId == userId)
            .first()
            ?? Entitlement(userId: userId, level: entitlementLevel, subscriptionId: subscription.id)
        entitlement.level = entitlementLevel
        entitlement.subscriptionId = subscription.id
        try await entitlement.save(on: db)
    }

    func preferredProductSort(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == "pro_annual" { return true }
        if rhs == "pro_annual" { return false }
        if lhs == "pro_monthly" { return true }
        if rhs == "pro_monthly" { return false }
        return lhs < rhs
    }

    func plan(for productId: String) -> String {
        let product = productId.lowercased()
        if product.contains("annual") || product.contains("year") {
            return "pro_annual"
        }
        if product.contains("monthly") || product.contains("month") {
            return "pro_monthly"
        }
        return productId.hasPrefix("pro_") ? productId : "pro_monthly"
    }

    func parseRevenueCatDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}
