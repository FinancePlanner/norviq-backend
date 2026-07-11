import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Scenario JSON storage")
struct ScenarioJSONTests {
    @Test
    func `nested scenario payload round trips without losing numeric types`() throws {
        let json = #"{"values":{"path_count":10000,"saved":true,"shocks":[{"target":"technology","percentage":-0.2}],"goal":null}}"#
        let decoded = try JSONDecoder().decode(ScenarioJSON.self, from: Data(json.utf8))

        #expect(decoded.values["path_count"]?.number == 10000)
        #expect(decoded.values["saved"] == .bool(true))
        #expect(decoded.values["shocks"]?.array?.first?.object?["target"]?.string == "technology")
        #expect(decoded.values["goal"] == .null)

        let encoded = try JSONEncoder().encode(decoded)
        #expect(try JSONDecoder().decode(ScenarioJSON.self, from: encoded) == decoded)
    }
}
