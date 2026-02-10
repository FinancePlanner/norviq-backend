import Fluent
import Vapor
import Foundation

final class SearchCache: Model, Content, @unchecked Sendable {
    static let schema = "search_cache"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "provider")
    var provider: String

    @Field(key: "normalized_query")
    var normalizedQuery: String

    @Field(key: "payload")
    var payload: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        provider: String,
        normalizedQuery: String,
        payload: String
    ) {
        self.id = id
        self.provider = provider
        self.normalizedQuery = normalizedQuery
        self.payload = payload
    }
}
