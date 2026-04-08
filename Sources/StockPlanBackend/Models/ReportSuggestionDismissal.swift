import Fluent
import Foundation

final class ReportSuggestionDismissal: Model, @unchecked Sendable {
    static let schema = "report_suggestion_dismissals"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "suggestion_id")
    var suggestionId: String

    @Field(key: "dismissed_at")
    var dismissedAt: Date

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        suggestionId: String,
        dismissedAt: Date = .now
    ) {
        self.id = id
        self.$user.id = userId
        self.suggestionId = suggestionId
        self.dismissedAt = dismissedAt
    }
}
