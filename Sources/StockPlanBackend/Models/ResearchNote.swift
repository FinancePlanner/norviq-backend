import Fluent
import Vapor
import Foundation

final class ResearchNote: Model, Content, @unchecked Sendable {
    static let schema = "research_notes"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "symbol")
    var symbol: String

    @Field(key: "title")
    var title: String?

    @Field(key: "thesis")
    var thesis: String

    @Field(key: "risks")
    var risks: String?

    @Field(key: "catalysts")
    var catalysts: String?

    @Field(key: "reference_links")
    var referenceLinks: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        userId: UUID,
        symbol: String,
        title: String? = nil,
        thesis: String,
        risks: String? = nil,
        catalysts: String? = nil,
        referenceLinks: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.symbol = symbol
        self.title = title
        self.thesis = thesis
        self.risks = risks
        self.catalysts = catalysts
        self.referenceLinks = referenceLinks
    }
}
