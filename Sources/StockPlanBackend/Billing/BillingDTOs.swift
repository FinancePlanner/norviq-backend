import Foundation
import Vapor

struct BillingContextResponse: Content, Equatable {
    let plan: String
    let entitlementLevel: String
    let isPro: Bool
    let isPremium: Bool
    let subscription: BillingSubscriptionDTO?
    let planOptions: [BillingPlanOptionDTO]
    let features: [BillingFeatureDTO]
    let usage: [BillingUsageDTO]
    let trialDaysRemaining: Int?
    let isTrialActive: Bool
    let generatedAt: Date

    init(
        plan: String,
        entitlementLevel: String,
        isPro: Bool? = nil,
        isPremium: Bool,
        subscription: BillingSubscriptionDTO?,
        planOptions: [BillingPlanOptionDTO] = [],
        features: [BillingFeatureDTO],
        usage: [BillingUsageDTO],
        trialDaysRemaining: Int? = nil,
        isTrialActive: Bool = false,
        generatedAt: Date
    ) {
        self.plan = plan
        self.entitlementLevel = entitlementLevel
        self.isPro = isPro ?? isPremium
        self.isPremium = isPremium
        self.subscription = subscription
        self.planOptions = planOptions
        self.features = features
        self.usage = usage
        self.trialDaysRemaining = trialDaysRemaining
        self.isTrialActive = isTrialActive
        self.generatedAt = generatedAt
    }
}

struct BillingPlanOptionDTO: Content, Equatable {
    let productId: String
    let plan: String
    let displayName: String
    let interval: String
    let rank: Int
    let badge: String?
    let isCurrent: Bool
    let changeKind: String
}

struct BillingSubscriptionDTO: Content, Equatable {
    let provider: String
    let store: String?
    let productId: String
    let plan: String
    let status: String
    let periodStartedAt: Date?
    let periodEndsAt: Date?
    let trialEndsAt: Date?
    let gracePeriodEndsAt: Date?
    let cancelledAt: Date?
    let isTrial: Bool
    let isInGracePeriod: Bool
    let hasBillingIssue: Bool
    let isCancelledButActive: Bool
    let renewsOrExpiresAt: Date?
    let willRenew: Bool?
    let accessEndsAt: Date?
    let pendingProductId: String?
    let pendingPlan: String?
    let pendingPlanEffectiveAt: Date?
}

struct BillingFeatureDTO: Content, Equatable {
    let key: String
    let title: String
    let available: Bool
    let requiredPlan: String?
    let reason: String?
    let limit: Int?
    let used: Int?
    let remaining: Int?
}

struct BillingUsageDTO: Content, Equatable {
    let key: String
    let used: Int
    let limit: Int?
    let remaining: Int?
    let periodStart: Date?
}

struct BillingUpgradeRequiredResponse: Content, Equatable {
    let success: Bool
    let code: String
    let error: String
    let feature: String
    let plan: String
    let requiredPlan: String
    let limit: Int?
    let current: Int?
}
