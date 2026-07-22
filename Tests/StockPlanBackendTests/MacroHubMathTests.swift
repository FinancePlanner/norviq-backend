import Foundation
@testable import StockPlanBackend
import Testing

@Suite("MacroHubMath Tests")
struct MacroHubMathTests {
    @Test("Sahm rule returns nil with short history")
    func sahmShortHistory() {
        #expect(MacroHubMath.sahmRule(unemploymentValues: [4.0, 4.1, 4.2]) == nil)
    }

    @Test("Sahm rule detects elevated rise from trough")
    func sahmElevated() throws {
        // 12 months flat at 3.5, then rise to 4.2 → 3-mo avg rises above trough by ~0.7
        var values = Array(repeating: 3.5, count: 14)
        values += [3.8, 4.0, 4.2]
        let sahm = MacroHubMath.sahmRule(unemploymentValues: values)
        #expect(sahm != nil)
        #expect(try #require(sahm) >= 0.50)
        #expect(MacroHubMath.riskLabel(sahm: sahm, officialRecession: false) == "elevated")
    }

    @Test("risk label respects NBER flag")
    func riskNBER() {
        #expect(MacroHubMath.riskLabel(sahm: 0.1, officialRecession: true) == "elevated")
        #expect(MacroHubMath.riskLabel(sahm: 0.35, officialRecession: false) == "watch")
        #expect(MacroHubMath.riskLabel(sahm: 0.1, officialRecession: false) == "low")
    }
}
