import StockPlanShared
import Vapor

struct BillingController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let billing = protected.grouped("billing")

        billing.get("me", use: me)
        billing.post("coupons", "validate", use: validateCoupon)
        billing.post("coupons", "redeem", use: redeemCoupon)
    }

    @Sendable
    func me(req: Request) async throws -> BillingContextResponse {
        let session = try req.auth.require(SessionToken.self)
        return try await req.billingContextService.context(userId: session.userId, on: req.db)
    }

    @Sendable
    func validateCoupon(req: Request) async throws -> CouponResponse {
        _ = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(CouponCodeRequest.self)
        return try await req.application.couponService.validateCoupon(code: payload.code, db: req.db)
    }

    @Sendable
    func redeemCoupon(req: Request) async throws -> CouponRedemptionResponse {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(CouponCodeRequest.self)
        guard let user = try await User.find(session.userId, on: req.db) else {
            throw Abort(.notFound, reason: "User not found.")
        }
        return try await req.application.couponService.redeemCoupon(code: payload.code, user: user, db: req.db)
    }
}
