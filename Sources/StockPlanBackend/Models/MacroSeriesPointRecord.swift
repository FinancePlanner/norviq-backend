import Fluent
import Foundation
import Vapor

/// One observation of a macro series (CPI YoY, treasury yield, item price...)
/// for a country, stored vintage-true: revisions insert a new row with a later
/// `vintage_date`; existing rows are never updated.
final class MacroSeriesPointRecord: Model, Content, @unchecked Sendable {
    static let schema = "macro_series_points"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "country")
    var country: String

    @Field(key: "series_key")
    var seriesKey: String

    @Field(key: "period_date")
    var periodDate: String

    @Field(key: "value")
    var value: Double

    @Field(key: "unit")
    var unit: String

    @Field(key: "source")
    var source: String

    @Field(key: "vintage_date")
    var vintageDate: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        country: String,
        seriesKey: String,
        periodDate: String,
        value: Double,
        unit: String,
        source: String,
        vintageDate: Date
    ) {
        self.id = id
        self.country = country
        self.seriesKey = seriesKey
        self.periodDate = periodDate
        self.value = value
        self.unit = unit
        self.source = source
        self.vintageDate = vintageDate
    }
}
