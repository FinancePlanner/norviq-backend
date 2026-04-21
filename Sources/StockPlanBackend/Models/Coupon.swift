import Fluent
import Vapor
import Foundation

final class Coupon: Model, Content, @unchecked Sendable {
    static let schema = "coupons"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "code")
    var code: String

    @Field(key: "trial_days")
    var trialDays: Int

    @OptionalField(key: "discount_percentage")
    var discountPercentage: Int?

    @OptionalField(key: "discount_amount")
    var discountAmount: Int?

    @OptionalField(key: "currency")
    var currency: String?

    @OptionalField(key: "max_uses")
    var maxUses: Int?

    @Field(key: "current_uses")
    var currentUses: Int

    @OptionalField(key: "expires_at")
    var expiresAt: Date?

    @Field(key: "is_active")
    var isActive: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        code: String,
        trialDays: Int,
        discountPercentage: Int? = nil,
        discountAmount: Int? = nil,
        currency: String? = nil,
        maxUses: Int? = nil,
        currentUses: Int = 0,
        expiresAt: Date? = nil,
        isActive: Bool = true
    ) {
        self.id = id
        self.code = code.uppercased()
        self.trialDays = trialDays
        self.discountPercentage = discountPercentage
        self.discountAmount = discountAmount
        self.currency = currency
        self.maxUses = maxUses
        self.currentUses = currentUses
        self.expiresAt = expiresAt
        self.isActive = isActive
    }
}
