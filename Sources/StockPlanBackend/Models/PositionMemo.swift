import Fluent
import Foundation
import Vapor

final class PositionMemo: Model, @unchecked Sendable {
    static let schema = "position_memos"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @OptionalField(key: "conversation_id") var conversationId: UUID?
    @Field(key: "asked_symbol") var askedSymbol: String
    @Field(key: "primary_symbol") var primarySymbol: String
    @Field(key: "title_encrypted") var titleEncrypted: Data
    @Field(key: "mark_encrypted") var markEncrypted: Data
    @Field(key: "sections_encrypted") var sectionsEncrypted: Data
    @Field(key: "verdict_encrypted") var verdictEncrypted: Data
    @Field(key: "sources_encrypted") var sourcesEncrypted: Data
    @Field(key: "evidence_encrypted") var evidenceEncrypted: Data
    @Field(key: "bookmarked") var bookmarked: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(
        userId: UUID,
        conversationId: UUID?,
        askedSymbol: String,
        primarySymbol: String,
        titleEncrypted: Data,
        markEncrypted: Data,
        sectionsEncrypted: Data,
        verdictEncrypted: Data,
        sourcesEncrypted: Data,
        evidenceEncrypted: Data,
        bookmarked: Bool = false
    ) {
        self.userId = userId
        self.conversationId = conversationId
        self.askedSymbol = askedSymbol
        self.primarySymbol = primarySymbol
        self.titleEncrypted = titleEncrypted
        self.markEncrypted = markEncrypted
        self.sectionsEncrypted = sectionsEncrypted
        self.verdictEncrypted = verdictEncrypted
        self.sourcesEncrypted = sourcesEncrypted
        self.evidenceEncrypted = evidenceEncrypted
        self.bookmarked = bookmarked
    }
}
