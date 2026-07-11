import Vapor

struct ScenarioCatalogResponse: Content {
    let version: String
    let historicalScenarios: [HistoricalScenarioPreset]
}

struct HistoricalScenarioPreset: Content {
    let id: String
    let name: String
    let startDate: String
    let endDate: String
}

enum ScenarioCatalog {
    static let version = "2026.1"
    static let response = ScenarioCatalogResponse(version: version, historicalScenarios: [
        .init(id: "dot_com_decline", name: "Dot-com decline", startDate: "2000-03-24", endDate: "2002-10-09"),
        .init(id: "global_financial_crisis", name: "Global financial crisis", startDate: "2007-10-09", endDate: "2009-03-09"),
        .init(id: "covid_crash", name: "COVID crash", startDate: "2020-02-19", endDate: "2020-03-23"),
        .init(id: "2022_rate_shock", name: "2022 rate shock", startDate: "2022-01-03", endDate: "2022-10-12"),
    ])
}
