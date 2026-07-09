import Fluent
import Foundation
import Vapor

/// Full inflation snapshot for a country as returned by a provider refresh.
/// `payload` is the JSON-encoded `InflationSnapshotResponse`. Insert-only:
/// a new row is appended when `as_of` or content changes; history preserved.
final class MacroSnapshotRecord: Model, Content, @unchecked Sendable {
    static let schema = "macro_snapshots"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "country")
    var country: String

    @Field(key: "as_of")
    var asOf: String

    @Field(key: "source")
    var source: String

    @Field(key: "payload")
    var payload: String

    @Field(key: "fetched_at")
    var fetchedAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        country: String,
        asOf: String,
        source: String,
        payload: String,
        fetchedAt: Date
    ) {
        self.id = id
        self.country = country
        self.asOf = asOf
        self.source = source
        self.payload = payload
        self.fetchedAt = fetchedAt
    }
}
