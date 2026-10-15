import Foundation
import StockPlanShared

/// The two languages a brief is written in. The app has no pt-BR, so any
/// `pt*` request gets European Portuguese.
enum MarketBriefLanguage: String, CaseIterable, Sendable {
    case en
    case ptPT = "pt-PT"

    static func resolve(_ raw: String?) -> MarketBriefLanguage {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), raw.hasPrefix("pt") else {
            return .en
        }
        return .ptPT
    }
}

/// Which symbols the brief shows, in which order, under which heading.
///
/// Yahoo has no European index futures (FDAX=F, FESX=F and FCE=F all 404),
/// which is why the morning brief runs after the European open and shows
/// opening moves of the cash indices.
enum MarketBriefCatalog {
    struct Instrument: Sendable, Equatable {
        let symbol: String
        let flag: String
        let name: String
    }

    struct GroupSpec: Sendable {
        let id: String
        let instruments: [Instrument]
    }

    static let dax = Instrument(symbol: "^GDAXI", flag: "🇩🇪", name: "DAX")
    static let cac = Instrument(symbol: "^FCHI", flag: "🇫🇷", name: "CAC 40")
    static let stoxx = Instrument(symbol: "^STOXX50E", flag: "🇪🇺", name: "Euro Stoxx 50")
    static let nasdaqFutures = Instrument(symbol: "NQ=F", flag: "🇺🇸", name: "Nasdaq 100")
    static let spFutures = Instrument(symbol: "ES=F", flag: "🇺🇸", name: "S&P 500")
    static let nasdaq = Instrument(symbol: "^NDX", flag: "🇺🇸", name: "Nasdaq 100")
    static let sp = Instrument(symbol: "^GSPC", flag: "🇺🇸", name: "S&P 500")
    static let dow = Instrument(symbol: "^DJI", flag: "🇺🇸", name: "Dow Jones")

    /// Facts for the model only; never rendered as rows. ^TNX's price is the
    /// yield in percent.
    static let context: [Instrument] = [
        Instrument(symbol: "^N225", flag: "🇯🇵", name: "Nikkei 225"),
        Instrument(symbol: "^HSI", flag: "🇭🇰", name: "Hang Seng"),
        Instrument(symbol: "BZ=F", flag: "🛢️", name: "Brent crude"),
        Instrument(symbol: "^TNX", flag: "🇺🇸", name: "US 10-year Treasury yield"),
    ]

    static func groups(for slot: MarketBriefSlot) -> [GroupSpec] {
        switch slot {
        case .morning:
            [
                GroupSpec(id: "eu_open", instruments: [dax, cac, stoxx]),
                GroupSpec(id: "us_futures", instruments: [nasdaqFutures, spFutures]),
            ]
        case .evening:
            [
                GroupSpec(id: "eu_close", instruments: [dax, cac, stoxx]),
                GroupSpec(id: "us_close", instruments: [nasdaq, sp, dow]),
            ]
        }
    }

    /// Everything fetched for a slot: its rows plus the context facts.
    static func instruments(for slot: MarketBriefSlot) -> [Instrument] {
        groups(for: slot).flatMap(\.instruments) + context
    }

    static func instrument(symbol: String) -> Instrument? {
        (MarketBriefSlot.allCases.flatMap { groups(for: $0).flatMap(\.instruments) } + context)
            .first { $0.symbol == symbol }
    }

    /// Headings agree in gender and number in Portuguese, hence a table rather
    /// than "<label> <tone word>".
    static func title(groupId: String, tone: MarketBriefDirection, language: MarketBriefLanguage) -> String {
        let entry = titles[groupId]?[tone] ?? (en: groupId, pt: groupId)
        return language == .en ? entry.en : entry.pt
    }

    private static let titles: [String: [MarketBriefDirection: (en: String, pt: String)]] = [
        "eu_open": [
            .up: ("European open higher", "Abertura europeia positiva"),
            .down: ("European open lower", "Abertura europeia negativa"),
            .flat: ("European open mixed", "Abertura europeia mista"),
        ],
        "us_futures": [
            .up: ("US futures higher", "Futuros americanos positivos"),
            .down: ("US futures lower", "Futuros americanos negativos"),
            .flat: ("US futures mixed", "Futuros americanos mistos"),
        ],
        "eu_close": [
            .up: ("Europe closed higher", "Europa fecha em alta"),
            .down: ("Europe closed lower", "Europa fecha em queda"),
            .flat: ("Europe closed mixed", "Europa fecha mista"),
        ],
        "us_close": [
            .up: ("Wall Street closed higher", "Wall Street fecha em alta"),
            .down: ("Wall Street closed lower", "Wall Street fecha em queda"),
            .flat: ("Wall Street closed mixed", "Wall Street fecha mista"),
        ],
    ]
}
