import Fluent
import Foundation
import StockPlanShared

/// One user's recap for one period. `payload` is the JSON-encoded `RecapDeck`,
/// frozen at generation and served as stored from then on.
final class RecapRecord: Model, @unchecked Sendable {
    static let schema = "recaps"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "period_kind")
    var periodKind: String

    @Field(key: "period_key")
    var periodKey: String

    @Field(key: "payload")
    var payload: String

    @OptionalField(key: "archetype")
    var archetype: String?

    @Field(key: "schema_version")
    var schemaVersion: Int

    @Field(key: "generated_at")
    var generatedAt: Date

    @OptionalField(key: "opened_at")
    var openedAt: Date?

    @OptionalField(key: "completed_at")
    var completedAt: Date?

    init() {}

    init(id: UUID? = nil, userId: UUID, deck: RecapDeck, generatedAt: Date) throws {
        self.id = id
        self.userId = userId
        periodKind = deck.kind.rawValue
        periodKey = deck.key
        // JSONEncoder output is always valid UTF-8.
        // swiftlint:disable:next optional_data_string_conversion
        payload = try String(decoding: Self.encoder.encode(deck), as: UTF8.self)
        archetype = deck.archetype?.rawValue
        schemaVersion = deck.schemaVersion
        self.generatedAt = generatedAt
    }

    func deck() throws -> RecapDeck {
        try JSONDecoder().decode(RecapDeck.self, from: Data(payload.utf8))
    }

    func response() throws -> RecapResponse {
        try RecapResponse(
            id: requireID(), deck: deck(), generatedAt: generatedAt,
            openedAt: openedAt, completedAt: completedAt
        )
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
