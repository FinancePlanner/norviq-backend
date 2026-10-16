import Fluent
import Foundation

/// The zone a user's recap periods are cut in: the `timeZone` of their latest
/// check-in (by `localDate`). Missing or not a valid identifier → UTC.
enum RecapTimeZoneResolver {
    // swiftlint:disable:next force_unwrapping
    static let utc = TimeZone(identifier: "UTC")!

    static func timeZone(for userId: UUID, on db: any Database) async throws -> TimeZone {
        let latest = try await GamificationCheckIn.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$localDate, .descending)
            .first()
        guard let identifier = latest?.timeZone, !identifier.isEmpty,
              let zone = TimeZone(identifier: identifier)
        else { return utc }
        return zone
    }
}
