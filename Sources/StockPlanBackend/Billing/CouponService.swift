import Fluent
import Foundation
import StockPlanShared
import Vapor

struct CouponCodeRequest: Content {
    let code: String
}

struct CouponDiscountDTO: Content, Equatable {
    let percentage: Int?
    let amount: Int?
    let currency: String?
}

struct CouponResponse: Content, Equatable {
    let code: String
    let grantType: String
    let trialDays: Int
    let discount: CouponDiscountDTO
    let expiresAt: Date?
}

struct CouponRedemptionResponse: Content, Equatable {
    let coupon: CouponResponse
    let trialDaysRemaining: Int?
    let isTrialActive: Bool
    let billingContext: BillingContextResponse?

    init(
        coupon: CouponResponse,
        trialDaysRemaining: Int?,
        isTrialActive: Bool,
        billingContext: BillingContextResponse? = nil
    ) {
        self.coupon = coupon
        self.trialDaysRemaining = trialDaysRemaining
        self.isTrialActive = isTrialActive
        self.billingContext = billingContext
    }

    func withBillingContext(_ context: BillingContextResponse) -> CouponRedemptionResponse {
        CouponRedemptionResponse(
            coupon: coupon,
            trialDaysRemaining: trialDaysRemaining,
            isTrialActive: isTrialActive,
            billingContext: context
        )
    }
}

protocol CouponServicing: Sendable {
    func validateCoupon(code: String, db: any Database) async throws -> CouponResponse
    func redeemCoupon(code: String, user: User, db: any Database) async throws -> CouponRedemptionResponse
}

struct CouponService: CouponServicing {
    private enum GrantType {
        static let trial = "trial"
        static let lifetimePro = "lifetime_pro"
    }

    private let trialService: any TrialServicing

    init(trialService: any TrialServicing) {
        self.trialService = trialService
    }

    func validateCoupon(code: String, db: any Database) async throws -> CouponResponse {
        let coupon = try await loadValidCoupon(code: code, db: db)
        return try makeCouponResponse(from: coupon)
    }

    func redeemCoupon(code: String, user: User, db: any Database) async throws -> CouponRedemptionResponse {
        try await db.transaction { tx in
            let coupon = try await loadValidCoupon(code: code, db: tx)
            guard let userID = user.id, let couponID = coupon.id else {
                throw Abort(.internalServerError, reason: "Could not redeem coupon.")
            }

            let alreadyRedeemed = try await CouponRedemption.query(on: tx)
                .filter(\.$userID == userID)
                .filter(\.$couponID == couponID)
                .first()
            guard alreadyRedeemed == nil else {
                throw Abort(.conflict, reason: "Coupon has already been redeemed.")
            }

            switch coupon.grantType {
            case GrantType.trial:
                try await trialService.initializeTrial(
                    user: user,
                    trialDays: coupon.trialDays,
                    tierName: "temporary",
                    db: tx
                )
            case GrantType.lifetimePro:
                try await upsertLifetimeProEntitlement(userID: userID, db: tx)
            default:
                throw Abort(.badRequest, reason: "Coupon grant type is invalid.")
            }

            let redemption = CouponRedemption(
                userID: userID,
                couponID: couponID,
                code: coupon.code,
                trialDaysGranted: coupon.trialDays,
                discountPercentage: coupon.discountPercentage,
                discountAmount: coupon.discountAmount,
                currency: coupon.currency
            )
            try await redemption.save(on: tx)

            coupon.currentUses += 1
            try await coupon.save(on: tx)

            let trialStatus = coupon.grantType == GrantType.trial
                ? trialService.checkTrialStatus(user: user)
                : .notOnTrial
            let daysRemaining: Int?
            let isTrialActive: Bool
            switch trialStatus {
            case let .active(days), let .expiringSoon(days):
                daysRemaining = days
                isTrialActive = true
            case .expired, .notOnTrial:
                daysRemaining = nil
                isTrialActive = false
            }

            return try CouponRedemptionResponse(
                coupon: makeCouponResponse(from: coupon),
                trialDaysRemaining: daysRemaining,
                isTrialActive: isTrialActive
            )
        }
    }

    private func loadValidCoupon(code: String, db: any Database) async throws -> Coupon {
        let normalizedCode = code.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCode.isEmpty else {
            throw Abort(.badRequest, reason: "Coupon code is required.")
        }

        guard let coupon = try await Coupon.query(on: db)
            .filter(\.$code == normalizedCode)
            .first()
        else {
            throw Abort(.notFound, reason: "Invalid coupon code.")
        }

        guard coupon.isActive else {
            throw Abort(.badRequest, reason: "This coupon is no longer active.")
        }

        if let expiresAt = coupon.expiresAt, expiresAt < Date() {
            throw Abort(.badRequest, reason: "This coupon has expired.")
        }

        if let maxUses = coupon.maxUses, coupon.currentUses >= maxUses {
            throw Abort(.badRequest, reason: "This coupon has reached its maximum usage limit.")
        }

        if coupon.grantType == GrantType.lifetimePro {
            guard coupon.maxUses == 1 else {
                throw Abort(.badRequest, reason: "Lifetime coupons must be configured for one use.")
            }
            guard coupon.trialDays == 0 else {
                throw Abort(.badRequest, reason: "Lifetime coupons cannot grant trial days.")
            }
        }

        return coupon
    }

    private func makeCouponResponse(from coupon: Coupon) throws -> CouponResponse {
        let trialDays = coupon.trialDays
        if coupon.grantType == GrantType.trial, trialDays <= 0 {
            throw Abort(.badRequest, reason: "Coupon trial duration is invalid.")
        }
        guard coupon.grantType == GrantType.trial || coupon.grantType == GrantType.lifetimePro else {
            throw Abort(.badRequest, reason: "Coupon grant type is invalid.")
        }
        return CouponResponse(
            code: coupon.code,
            grantType: coupon.grantType,
            trialDays: trialDays,
            discount: CouponDiscountDTO(
                percentage: coupon.discountPercentage,
                amount: coupon.discountAmount,
                currency: coupon.currency
            ),
            expiresAt: coupon.expiresAt
        )
    }

    private func upsertLifetimeProEntitlement(userID: UUID, db: any Database) async throws {
        let entitlement = try await Entitlement.query(on: db)
            .filter(\.$userId == userID)
            .first()
            ?? Entitlement(userId: userID, level: "pro", subscriptionId: nil)
        entitlement.level = "pro"
        entitlement.subscriptionId = nil
        try await entitlement.save(on: db)
    }
}

extension Application {
    private struct CouponServiceKey: StorageKey {
        typealias Value = any CouponServicing
    }

    var couponService: any CouponServicing {
        get {
            guard let service = storage[CouponServiceKey.self] else {
                return CouponService(trialService: trialService)
            }
            return service
        }
        set {
            storage[CouponServiceKey.self] = newValue
        }
    }
}
