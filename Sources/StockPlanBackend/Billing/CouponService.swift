import Fluent
import Foundation
import Vapor

struct CouponCodeRequest: Content, Sendable {
    let code: String
}

struct CouponDiscountDTO: Content, Sendable, Equatable {
    let percentage: Int?
    let amount: Int?
    let currency: String?
}

struct CouponResponse: Content, Sendable, Equatable {
    let code: String
    let trialDays: Int
    let discount: CouponDiscountDTO
    let expiresAt: Date?
}

struct CouponRedemptionResponse: Content, Sendable, Equatable {
    let coupon: CouponResponse
    let trialDaysRemaining: Int?
    let isTrialActive: Bool
}

protocol CouponServicing: Sendable {
    func validateCoupon(code: String, db: any Database) async throws -> CouponResponse
    func redeemCoupon(code: String, user: User, db: any Database) async throws -> CouponRedemptionResponse
}

struct CouponService: CouponServicing {
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

            try await trialService.initializeTrial(
                user: user,
                trialDays: coupon.trialDays,
                tierName: "temporary",
                db: tx
            )

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

            let trialStatus = trialService.checkTrialStatus(user: user)
            let daysRemaining: Int?
            let isTrialActive: Bool
            switch trialStatus {
            case .active(let days), .expiringSoon(let days):
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
            .first() else {
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

        return coupon
    }

    private func makeCouponResponse(from coupon: Coupon) throws -> CouponResponse {
        let trialDays = coupon.trialDays
        guard trialDays > 0 else {
            throw Abort(.badRequest, reason: "Coupon trial duration is invalid.")
        }
        return CouponResponse(
            code: coupon.code,
            trialDays: trialDays,
            discount: CouponDiscountDTO(
                percentage: coupon.discountPercentage,
                amount: coupon.discountAmount,
                currency: coupon.currency
            ),
            expiresAt: coupon.expiresAt
        )
    }
}

extension Application {
    private struct CouponServiceKey: StorageKey {
        typealias Value = any CouponServicing
    }

    var couponService: any CouponServicing {
        get {
            guard let service = storage[CouponServiceKey.self] else {
                return CouponService(trialService: self.trialService)
            }
            return service
        }
        set {
            storage[CouponServiceKey.self] = newValue
        }
    }
}
