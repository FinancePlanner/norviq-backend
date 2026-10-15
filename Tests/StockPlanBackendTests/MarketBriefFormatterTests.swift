import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Market brief formatting")
struct MarketBriefFormatterTests {
    private let now = Date(timeIntervalSince1970: 1_791_500_000)

    private func quote(_ symbol: String, _ price: Double, _ previous: Double) -> IndexQuote {
        IndexQuote(symbol: symbol, price: price, previousClose: previous, marketTime: now)
    }

    @Test("Index levels: dot thousands in pt-PT, comma thousands in en, no decimals at 1000+")
    func levels() {
        #expect(MarketBriefFormatter.level(25032.36, language: .ptPT) == "25.032")
        #expect(MarketBriefFormatter.level(25032.36, language: .en) == "25,032")
        #expect(MarketBriefFormatter.level(1_234_567, language: .en) == "1,234,567")
        #expect(MarketBriefFormatter.level(7698.4, language: .ptPT) == "7.698")
    }

    @Test("Small levels keep two decimals")
    func smallLevels() {
        #expect(MarketBriefFormatter.level(104.1, language: .ptPT) == "104,10")
        #expect(MarketBriefFormatter.level(104.1, language: .en) == "104.10")
        #expect(MarketBriefFormatter.level(5.231, language: .en) == "5.23")
    }

    @Test("Percent is unsigned; direction carries the sign")
    func percents() {
        #expect(MarketBriefFormatter.percent(-0.774, language: .ptPT) == "0,77%")
        #expect(MarketBriefFormatter.percent(-0.774, language: .en) == "0.77%")
        #expect(MarketBriefFormatter.percent(1.156, language: .ptPT) == "1,16%")
        #expect(MarketBriefFormatter.direction(-0.774) == .down)
        #expect(MarketBriefFormatter.direction(0.006) == .up)
        #expect(MarketBriefFormatter.direction(-0.004) == .flat)
    }

    @Test("Tone is the mean move with a ±0.15 point flat band")
    func tone() {
        #expect(MarketBriefFormatter.tone([-0.77, -0.94, -1.15]) == .down)
        #expect(MarketBriefFormatter.tone([0.4, 0.2]) == .up)
        #expect(MarketBriefFormatter.tone([0.1, -0.1]) == .flat)
        #expect(MarketBriefFormatter.tone([]) == .flat)
    }

    @Test("Morning groups: rows in catalog order, missing instruments skipped, empty groups dropped")
    func morningGroups() {
        let quotes = [quote("NQ=F", 31243, 31403), quote("^GDAXI", 25032, 25226)]
        let groups = MarketBriefFormatter.groups(slot: .morning, quotes: quotes, language: .ptPT)
        #expect(groups.map(\.id) == ["eu_open", "us_futures"])
        #expect(groups[0].rows.map(\.name) == ["DAX"])
        #expect(groups[0].rows[0].level == "25.032")
        #expect(groups[0].rows[0].changePercent == "0,77%")
        #expect(groups[0].rows[0].direction == .down)
        #expect(groups[0].title == "Abertura europeia negativa")
        #expect(groups[1].title == "Futuros americanos negativos")

        let usOnly = MarketBriefFormatter.groups(slot: .morning, quotes: [quote("ES=F", 7830, 7877)], language: .en)
        #expect(usOnly.map(\.id) == ["us_futures"])
        #expect(usOnly[0].title == "US futures lower")
    }

    @Test("Context instruments never become rows")
    func contextNotRows() {
        let groups = MarketBriefFormatter.groups(slot: .morning, quotes: [quote("BZ=F", 104, 100)], language: .en)
        #expect(groups.isEmpty)
    }

    @Test("Language resolution: pt-anything is pt-PT, everything else is en")
    func languageResolution() {
        #expect(MarketBriefLanguage.resolve("pt-PT") == .ptPT)
        #expect(MarketBriefLanguage.resolve("pt") == .ptPT)
        #expect(MarketBriefLanguage.resolve("PT-pt") == .ptPT)
        #expect(MarketBriefLanguage.resolve("pt-BR") == .ptPT)
        #expect(MarketBriefLanguage.resolve("de") == .en)
        #expect(MarketBriefLanguage.resolve(nil) == .en)
        #expect(MarketBriefLanguage.resolve("") == .en)
    }
}
