@testable import StockPlanBackend
import Testing

@Suite("Macro Provider Selection Tests")
struct MacroProviderSelectionTests {
    @Test("macro disabled turns every country off")
    func macroDisabled() {
        let plan = MacroProviderPlanSelection.plan(macroEnabled: false, hasFREDKey: true, nowflationConfigured: true)
        for country in MacroCountry.allCases {
            #expect(plan[country]?.primary == .disabled)
            #expect(plan[country]?.nowflationEnrichment == false)
        }
    }

    @Test("full configuration: FRED primary US with Nowflation, official providers elsewhere with FRED fallback")
    func fullConfiguration() {
        let plan = MacroProviderPlanSelection.plan(macroEnabled: true, hasFREDKey: true, nowflationConfigured: true)
        #expect(plan[.us] == .init(primary: .fred, fallback: nil, nowflationEnrichment: true))
        #expect(plan[.br] == .init(primary: .ibge, fallback: .fred, nowflationEnrichment: false))
        #expect(plan[.pt] == .init(primary: .eurostat, fallback: .fred, nowflationEnrichment: false))
        #expect(plan[.ea] == .init(primary: .eurostat, fallback: .fred, nowflationEnrichment: false))
    }

    @Test("no FRED key: US disabled, intl providers keep working without fallback")
    func noFREDKey() {
        let plan = MacroProviderPlanSelection.plan(macroEnabled: true, hasFREDKey: false, nowflationConfigured: true)
        #expect(plan[.us]?.primary == .disabled)
        #expect(plan[.us]?.nowflationEnrichment == false) // enrichment needs a FRED base
        #expect(plan[.br] == .init(primary: .ibge, fallback: nil, nowflationEnrichment: false))
        #expect(plan[.pt] == .init(primary: .eurostat, fallback: nil, nowflationEnrichment: false))
    }

    @Test("FRED without Nowflation: US live but official-only")
    func fredOnly() {
        let plan = MacroProviderPlanSelection.plan(macroEnabled: true, hasFREDKey: true, nowflationConfigured: false)
        #expect(plan[.us] == .init(primary: .fred, fallback: nil, nowflationEnrichment: false))
    }

    @Test("country query parsing accepts aliases and rejects unknowns")
    func countryParsing() {
        #expect(MacroCountry(query: "us") == .us)
        #expect(MacroCountry(query: " BR ") == .br)
        #expect(MacroCountry(query: "EURO") == .ea)
        #expect(MacroCountry(query: "EZ") == .ea)
        #expect(MacroCountry(query: "XX") == nil)
        #expect(MacroCountry(query: nil) == nil)
    }

    @Test("series key resolution maps legacy names")
    func seriesKeyResolution() {
        #expect(MacroSeriesKey.resolve("nowflation_cpi") == "nowflation_gauge")
        #expect(MacroSeriesKey.resolve("official_cpi") == "headline_cpi")
        #expect(MacroSeriesKey.resolve("headline") == "headline_cpi")
        #expect(MacroSeriesKey.resolve("core") == "core_cpi")
        #expect(MacroSeriesKey.resolve(nil) == "headline_cpi")
        #expect(MacroSeriesKey.resolve("dgs10") == "dgs10")
        #expect(MacroSeriesKey.itemKey("eggs") == "item.eggs")
    }
}
