import Foundation
import StockPlanShared
import Vapor

extension NetWorthForecastDefinition: @retroactive Content {}
extension NetWorthForecastUpsertRequest: @retroactive Content {}
extension NetWorthForecastDefaults: @retroactive Content {}
extension NetWorthForecastRun: @retroactive Content {}
extension ScreenMetricDescriptor: @retroactive Content {}
extension WatchlistScreen: @retroactive Content {}
extension WatchlistScreenUpsertRequest: @retroactive Content {}
extension WatchlistScreenEvaluation: @retroactive Content {}
extension RebalancingPolicy: @retroactive Content {}
extension RebalancingPolicyUpsertRequest: @retroactive Content {}
extension RebalancePreview: @retroactive Content {}
extension RebalanceEvent: @retroactive Content {}
extension NotificationInboxItem: @retroactive Content {}
extension NotificationInboxPage: @retroactive Content {}
extension NotificationReadRequest: @retroactive Content {}

enum WealthAutomationCoding {
    static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.keyEncodingStrategy = .convertToSnakeCase
        return value
    }()

    static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.keyDecodingStrategy = .convertFromSnakeCase
        return value
    }()

    static func json(_ value: some Encodable) throws -> ScenarioJSON {
        try decoder.decode(ScenarioJSON.self, from: encoder.encode(value))
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: ScenarioJSON) throws -> T {
        try decoder.decode(type, from: encoder.encode(value))
    }

    static func timestamp(_ date: Date?) -> String? {
        date.map { ISO8601DateFormatter().string(from: $0) }
    }
}
