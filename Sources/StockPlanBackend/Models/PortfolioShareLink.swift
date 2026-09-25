import Fluent
import Foundation

/// A live, revocable public link to a percent-only view of one portfolio (or
/// all of a user's actual portfolios when `portfolioListId` is nil). The slug
/// is stored in plaintext on purpose: it is a public URL the owner must be able
/// to copy again, and revocation — not secrecy of storage — is the control.
final class PortfolioShareLink: Model, @unchecked Sendable {
    static let schema = "portfolio_share_links"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @OptionalField(key: "portfolio_list_id")
    var portfolioListId: UUID?

    @Field(key: "slug")
    var slug: String

    @OptionalField(key: "revoked_at")
    var revokedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(userId: UUID, portfolioListId: UUID?, slug: String) {
        self.userId = userId
        self.portfolioListId = portfolioListId
        self.slug = slug
    }
}
