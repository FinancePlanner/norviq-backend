import Fluent
import Foundation
import Vapor

final class CouponRedemption: Model, Content, @unchecked Sendable {
    static let schema = "coupon_redemptions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "coupon_id")
    var couponID: UUID

    @Field(key: "code")
    var code: String

    @Field(key: "trial_days_granted")
    var trialDaysGranted: Int

    @OptionalField(key: "discount_percentage")
    var discountPercentage: Int?

    @OptionalField(key: "discount_amount")
    var discountAmount: Int?

    @OptionalField(key: "currency")
    var currency: String?

    @Timestamp(key: "redeemed_at", on: .create)
    var redeemedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        couponID: UUID,
        code: String,
        trialDaysGranted: Int,
        discountPercentage: Int? = nil,
        discountAmount: Int? = nil,
        currency: String? = nil
    ) {
        self.id = id
        self.userID = userID
        self.couponID = couponID
        self.code = code.uppercased()
        self.trialDaysGranted = trialDaysGranted
        self.discountPercentage = discountPercentage
        self.discountAmount = discountAmount
        self.currency = currency
    }
}
