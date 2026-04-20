import Vapor

extension Application {
    struct BillingServiceKey: StorageKey {
        typealias Value = any BillingService
    }

    struct EntitlementResolverKey: StorageKey {
        typealias Value = any EntitlementResolver
    }

    struct UsageCounterServiceKey: StorageKey {
        typealias Value = any UsageCounterService
    }

    var billingService: any BillingService {
        get { storage[BillingServiceKey.self]! }
        set { storage[BillingServiceKey.self] = newValue }
    }

    var entitlementResolver: any EntitlementResolver {
        get { storage[EntitlementResolverKey.self]! }
        set { storage[EntitlementResolverKey.self] = newValue }
    }

    var usageCounterService: any UsageCounterService {
        get { storage[UsageCounterServiceKey.self]! }
        set { storage[UsageCounterServiceKey.self] = newValue }
    }
}

extension Request {
    var billingService: any BillingService {
        application.billingService
    }

    var entitlementResolver: any EntitlementResolver {
        application.entitlementResolver
    }

    var usageCounterService: any UsageCounterService {
        application.usageCounterService
    }
}
