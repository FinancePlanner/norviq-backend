import Foundation

// MARK: - Topics and the weekly rotation

enum DailyBoardTopic: String, Equatable, Sendable, CaseIterable {
    /// Hot stock: the most-named ticker in the day's headlines that moved.
    case stock
    case mag7
    case macro
    case etf
    case weekRecap = "week_recap"
    case weekAhead = "week_ahead"
    /// v1 topics. Not scheduled any more; kept so old run rows still decode.
    case index
    case news
}

/// One topic per weekday, so members know what tomorrow brings. When a slot
/// cannot be filled (a holiday leaves no hot stock), the fallbacks run in
/// order; when none can, the day is skipped.
enum DailyBoardRotation {
    static let fallbacks: [DailyBoardTopic] = [.etf, .macro]

    static func slot(for day: String) -> DailyBoardTopic? {
        guard let weekday = weekday(day) else { return nil }
        switch weekday {
        case 2: return .mag7
        case 3, 6: return .stock
        case 4: return .macro
        case 5: return .etf
        case 7: return .weekRecap
        default: return .weekAhead
        }
    }

    static func topics(for day: String) -> [DailyBoardTopic] {
        guard let slot = slot(for: day) else { return [] }
        return [slot] + fallbacks.filter { $0 != slot }
    }

    /// Gregorian weekday of a yyyy-MM-dd day: 1 is Sunday, 7 is Saturday.
    static func weekday(_ day: String) -> Int? {
        guard let date = DailyBoardDays.date(day) else { return nil }
        return DailyBoardDays.calendar.component(.weekday, from: date)
    }
}

/// Calendar arithmetic on yyyy-MM-dd strings, in UTC so no day is lost to a
/// clock change.
enum DailyBoardDays {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func date(_ day: String) -> Date? {
        formatter.date(from: day)
    }

    static func adding(_ days: Int, to day: String) -> String? {
        guard let date = date(day), let moved = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return formatter.string(from: moved)
    }

    /// "2026-09-01" reads "September 2026". Used for monthly macro periods.
    static func monthName(_ day: String) -> String {
        guard let date = date(day) else { return day }
        let month = DateFormatter()
        month.dateFormat = "MMMM yyyy"
        month.timeZone = TimeZone(identifier: "UTC")
        month.locale = Locale(identifier: "en_US_POSIX")
        return month.string(from: date)
    }

    /// "2026-10-26" reads "Monday 2026-10-26".
    static func withWeekday(_ day: String) -> String {
        guard let date = date(day) else { return day }
        let weekday = DateFormatter()
        weekday.dateFormat = "EEEE"
        weekday.timeZone = TimeZone(identifier: "UTC")
        weekday.locale = Locale(identifier: "en_US_POSIX")
        return "\(weekday.string(from: date)) \(day)"
    }
}

// MARK: - What each topic draws from

enum DailyBoardCatalog {
    static let mag7 = ["AAPL", "MSFT", "GOOGL", "AMZN", "META", "NVDA", "TSLA"]

    /// Large US companies outside the Mag 7, ranked by the day's move when
    /// the market overview is unavailable. US listings only, so every quote
    /// provider covers them.
    static let largeCaps = [
        "AVGO", "AMD", "ORCL", "NFLX", "PLTR", "CRM", "ADBE", "INTC", "QCOM", "MU",
        "JPM", "BAC", "GS", "V", "MA", "BRK.B",
        "LLY", "UNH", "JNJ", "MRK", "ABBV",
        "WMT", "COST", "HD", "KO", "PEP", "NKE", "DIS",
        "XOM", "CVX", "BA", "UBER", "COIN",
    ]

    struct Fund: Equatable, Sendable {
        let symbol: String
        let name: String
        let tracks: String
        /// Total expense ratio in percent, from the issuer's fund page. Nil
        /// when it could not be confirmed: the post then leaves the fee out.
        let expenseRatio: Double?
    }

    /// Expense ratios and benchmarks from each issuer's own fund page or
    /// fact sheet, Yahoo symbols checked, all on 2026-10-19. Refresh yearly.
    static let funds: [Fund] = [
        Fund(symbol: "SPY", name: "SPDR S&P 500 ETF Trust", tracks: "S&P 500", expenseRatio: 0.0945),
        Fund(symbol: "QQQ", name: "Invesco QQQ Trust", tracks: "Nasdaq-100", expenseRatio: 0.18),
        Fund(symbol: "VTI", name: "Vanguard Total Stock Market ETF", tracks: "Morningstar US Total Market", expenseRatio: 0.03),
        Fund(symbol: "VOO", name: "Vanguard S&P 500 ETF", tracks: "S&P 500", expenseRatio: 0.03),
        Fund(symbol: "SCHD", name: "Schwab U.S. Dividend Equity ETF", tracks: "Dow Jones U.S. Dividend 100", expenseRatio: 0.06),
        Fund(symbol: "GLD", name: "SPDR Gold Shares", tracks: "the gold price (LBMA Gold Price PM)", expenseRatio: 0.40),
        Fund(symbol: "TLT", name: "iShares 20+ Year Treasury Bond ETF", tracks: "ICE US Treasury 20+ Year", expenseRatio: 0.15),
        Fund(symbol: "IWDA.AS", name: "iShares Core MSCI World UCITS ETF", tracks: "MSCI World", expenseRatio: 0.20),
        Fund(symbol: "VWCE.DE", name: "Vanguard FTSE All-World UCITS ETF (Acc)", tracks: "FTSE All-World", expenseRatio: 0.14),
        Fund(symbol: "EXW1.DE", name: "iShares Core EURO STOXX 50 UCITS ETF (DE)", tracks: "EURO STOXX 50", expenseRatio: 0.10),
        Fund(symbol: "CSPX.L", name: "iShares Core S&P 500 UCITS ETF", tracks: "S&P 500", expenseRatio: 0.07),
        Fund(symbol: "EIMI.L", name: "iShares Core MSCI EM IMI UCITS ETF", tracks: "MSCI Emerging Markets IMI", expenseRatio: 0.18),
    ]

    static let recapIndexes: [(symbol: String, name: String)] = [
        ("^GSPC", "S&P 500"),
        ("^NDX", "Nasdaq 100"),
        ("^STOXX50E", "Euro Stoxx 50"),
        ("^GDAXI", "DAX"),
        ("^N225", "Nikkei 225"),
    ]

    /// Earnings worth a line in the week ahead: the Mag 7, other large US
    /// names, and the US listings of big European and Asian companies.
    static let earningsWatch: Set<String> = Set(mag7 + [
        "AVGO", "AMD", "ORCL", "NFLX", "JPM", "V", "MA", "LLY", "UNH", "WMT", "COST", "XOM", "BRK.B",
        "ASML", "SAP", "NVO",
        "TSM", "BABA", "TM", "SONY", "TCEHY",
    ])
}

/// What earlier daily posts covered, newest first, read from their tags.
struct DailyBoardHistory: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let day: String
        let topic: DailyBoardTopic?
        let tags: [String]
    }

    var entries: [Entry] = []

    /// Tags of the last `count` posts on `topic`.
    func recentTags(_ topic: DailyBoardTopic, count: Int) -> Set<String> {
        Set(entries.filter { $0.topic == topic }.prefix(count).flatMap(\.tags))
    }

    /// The newest day a post on `topic` carried `tag`.
    func lastDay(_ tag: String, topic: DailyBoardTopic) -> String? {
        entries.first { $0.topic == topic && $0.tags.contains(tag) }?.day
    }

    static func tag(_ symbol: String) -> String {
        symbol.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - Facts

struct DailyBoardFact: Equatable, Sendable {
    let label: String
    let value: String
}

struct DailyBoardCandidate: Equatable, Sendable {
    var topic: DailyBoardTopic
    /// What the post is about, in words: "NVDA", "SPDR S&P 500 ETF Trust".
    var name: String
    var symbol: String = ""
    var facts: [DailyBoardFact] = []
    /// Every number the post may cite. Built with the facts, never after.
    var grounded: [Double] = []
    var url: String?
    /// The macro post's angle, stored as a tag so the next one differs.
    var angle: String?

    /// Tags the post is stored with: topic, ticker or angle, and "ai".
    var tags: [String] {
        var tags = [topic.rawValue]
        let symbolTag = DailyBoardHistory.tag(symbol)
        if !symbolTag.isEmpty {
            tags.append(symbolTag)
        }
        if let angle {
            tags.append(angle)
        }
        tags.append("ai")
        return tags
    }
}

/// Collects facts and the numbers they ground in one pass, so a figure the
/// model is shown is always a figure the validator accepts. Every number is
/// rounded here, to the precision the model is told to copy.
struct DailyBoardFactSheet {
    private(set) var facts: [DailyBoardFact] = []
    private(set) var grounded: [Double] = []

    /// Count of numeric facts, which is what makes a post worth reading.
    private(set) var figures = 0

    mutating func text(_ label: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        facts.append(DailyBoardFact(label: label, value: value))
    }

    /// A price or level, two decimals. `unit` follows the number ("USD").
    mutating func price(_ label: String, _ value: Double?, unit: String? = nil) {
        guard let value = Self.finite(value) else { return }
        let rounded = Self.round(value, 2)
        add(label, Self.format(rounded, 2) + (unit.map { " \($0)" } ?? ""), rounded)
    }

    /// A percent change, one decimal, signed. "-2.3%" reads as 2.3 to the
    /// grounding check, so both signs are grounded.
    mutating func percent(_ label: String, _ value: Double?) {
        guard let value = Self.finite(value) else { return }
        let rounded = Self.round(value, 1)
        add(label, (rounded > 0 ? "+" : "") + Self.format(rounded, 1) + "%", rounded)
    }

    /// A level that is itself a percent, like a 2.9% inflation rate.
    mutating func rate(_ label: String, _ value: Double?) {
        guard let value = Self.finite(value) else { return }
        let rounded = Self.round(value, 2)
        add(label, Self.format(rounded, 2) + "%", rounded)
    }

    /// A yearly fund fee, as precise as the issuer states it: "0.0945%".
    mutating func fee(_ label: String, _ value: Double?) {
        guard let value = Self.finite(value), value >= 0 else { return }
        var text = Self.format(value, 4)
        while text.hasSuffix("0"), !text.hasSuffix(".00") {
            text.removeLast()
        }
        add(label, text + "%", value)
    }

    /// A gap between two rates, in percentage points, signed.
    mutating func points(_ label: String, _ value: Double?) {
        guard let value = Self.finite(value) else { return }
        let rounded = Self.round(value, 2)
        add(label, (rounded > 0 ? "+" : "") + Self.format(rounded, 2) + " percentage points", rounded)
    }

    /// A multiple like P/E, one decimal so the check can see it: "31.4x".
    mutating func multiple(_ label: String, _ value: Double?) {
        guard let value = Self.finite(value), value > 0 else { return }
        let rounded = Self.round(value, 1)
        add(label, Self.format(rounded, 1) + "x", rounded)
    }

    /// Market cap from Finnhub's millions, shown in billions or trillions.
    /// Grounded in all three units in case the model converts.
    mutating func marketCap(_ label: String, millions: Double?) {
        guard let millions = Self.finite(millions), millions > 0 else { return }
        let text: String
        let shown: Double
        if millions >= 1_000_000 {
            shown = Self.round(millions / 1_000_000, 2)
            text = "$\(Self.format(shown, 2)) trillion"
        } else {
            shown = Self.round(millions / 1000, 1)
            text = "$\(Self.format(shown, 1)) billion"
        }
        add(label, text, shown)
        grounded += [millions, millions / 1000, millions / 1_000_000]
    }

    /// A plain number the post may cite, like an EPS estimate.
    mutating func number(_ label: String, _ value: Double?, decimals: Int = 2) {
        guard let value = Self.finite(value) else { return }
        let rounded = Self.round(value, decimals)
        add(label, Self.format(rounded, decimals), rounded)
    }

    /// Grounds numbers without listing them as facts: those in a headline
    /// the post may quote.
    mutating func ground(_ numbers: [Double]) {
        grounded += numbers
    }

    func candidate(
        topic: DailyBoardTopic,
        name: String,
        symbol: String = "",
        url: String? = nil,
        angle: String? = nil
    ) -> DailyBoardCandidate {
        DailyBoardCandidate(
            topic: topic, name: name, symbol: symbol, facts: facts, grounded: grounded, url: url, angle: angle
        )
    }

    private mutating func add(_ label: String, _ text: String, _ value: Double) {
        facts.append(DailyBoardFact(label: label, value: text))
        grounded += [value, abs(value)]
        figures += 1
    }

    static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    static func round(_ value: Double, _ decimals: Int) -> Double {
        let scale = pow(10, Double(decimals))
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    static func format(_ value: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

// MARK: - Builders

/// Pure: turns fetched data into a candidate, or nil when there is too
/// little to say. A post needs at least `minimumFigures` numbers behind it.
enum DailyBoardBuilders {
    static let minimumFigures = 4

    // MARK: Stocks

    struct StockSnapshot: Equatable, Sendable {
        var symbol: String
        var price: Double
        var changePercent: Double?
        /// The session the price is from, yyyy-MM-dd. On a weekend or a
        /// holiday it is the last trading day, and the post says so.
        var sessionDate: String
        /// Finnhub basic-financials metrics, by Finnhub's key.
        var metrics: [String: Double] = [:]
        var nextEarnings: String?
        var headline: DailyBoardFacts.Headline?
    }

    static func stock(_ snapshot: StockSnapshot, topic: DailyBoardTopic) -> DailyBoardCandidate? {
        var sheet = DailyBoardFactSheet()
        sheet.text("Ticker", snapshot.symbol)
        sheet.text("Session", DailyBoardDays.withWeekday(snapshot.sessionDate))
        sheet.price("Close", snapshot.price, unit: "USD")
        sheet.percent("Change on the session", snapshot.changePercent)
        sheet.percent("Change over 5 days", snapshot.metrics["5DayPriceReturnDaily"])
        sheet.percent("Change this year", snapshot.metrics["yearToDatePriceReturnDaily"])
        sheet.percent("Change over 52 weeks", snapshot.metrics["52WeekPriceReturnDaily"])
        let high = snapshot.metrics["52WeekHigh"]
        sheet.price("52-week high", high, unit: "USD")
        sheet.price("52-week low", snapshot.metrics["52WeekLow"], unit: "USD")
        if let high, high > 0 {
            sheet.percent("Distance from the 52-week high", (snapshot.price / high - 1) * 100)
        }
        sheet.marketCap("Market cap", millions: snapshot.metrics["marketCapitalization"])
        sheet.multiple("Price to trailing earnings (P/E)", snapshot.metrics["peTTM"])
        sheet.text("Next earnings report", snapshot.nextEarnings)
        sheet.text("Headline that named it", snapshot.headline?.title)
        if let headline = snapshot.headline?.title {
            sheet.ground(MarketBriefNumbers.tokens(in: headline).flatMap(\.readings))
        }
        guard sheet.figures >= minimumFigures else { return nil }
        return sheet.candidate(topic: topic, name: snapshot.symbol, symbol: snapshot.symbol)
    }

    /// The Mag 7 name with the biggest five-day move that was not one of the
    /// last three Mag 7 posts.
    static func pickMag7(_ snapshots: [StockSnapshot], history: DailyBoardHistory) -> StockSnapshot? {
        let recent = history.recentTags(.mag7, count: 3)
        let fresh = snapshots.filter { !recent.contains(DailyBoardHistory.tag($0.symbol)) }
        return (fresh.isEmpty ? snapshots : fresh).max { lhs, rhs in
            abs(lhs.metrics["5DayPriceReturnDaily"] ?? 0) < abs(rhs.metrics["5DayPriceReturnDaily"] ?? 0)
        }
    }

    // MARK: ETFs

    /// Catalog funds, least recently covered first, catalog order on ties.
    static func etfOrder(history: DailyBoardHistory) -> [DailyBoardCatalog.Fund] {
        DailyBoardCatalog.funds.enumerated().sorted { lhs, rhs in
            let left = history.lastDay(DailyBoardHistory.tag(lhs.element.symbol), topic: .etf) ?? ""
            let right = history.lastDay(DailyBoardHistory.tag(rhs.element.symbol), topic: .etf) ?? ""
            return left == right ? lhs.offset < rhs.offset : left < right
        }
        .map(\.element)
    }

    static func etf(_ fund: DailyBoardCatalog.Fund, series: DailyBarSeries) -> DailyBoardCandidate? {
        guard let last = series.last else { return nil }
        var sheet = DailyBoardFactSheet()
        sheet.text("Fund", "\(fund.name) (\(fund.symbol))")
        sheet.text("Tracks", fund.tracks)
        sheet.fee("Total expense ratio per year", fund.expenseRatio)
        sheet.text("Session", DailyBoardDays.withWeekday(last.date))
        sheet.price("Close", last.close, unit: series.currency)
        sheet.percent("Change on the session", series.percentChange(sessionsBack: 1))
        sheet.percent("Change over 5 sessions", series.percentChange(sessionsBack: 5))
        if let year = Int(last.date.prefix(4)) {
            sheet.percent("Change this year", series.percentChange(sinceCloseBefore: "\(year)-01-01"))
        }
        if let yearAgo = DailyBoardDays.adding(-365, to: last.date) {
            sheet.percent("Change over 1 year", series.percentChange(sinceCloseBefore: yearAgo))
        }
        sheet.price("52-week closing high", series.high52, unit: series.currency)
        sheet.price("52-week closing low", series.low52, unit: series.currency)
        if let high = series.high52, high > 0 {
            sheet.percent("Distance from the 52-week high", (last.close / high - 1) * 100)
        }
        guard sheet.figures >= minimumFigures else { return nil }
        return sheet.candidate(topic: .etf, name: fund.name, symbol: fund.symbol)
    }

    // MARK: Macro

    struct MacroReading: Equatable, Sendable {
        /// yyyy-MM-dd, first of the month for monthly series.
        let period: String
        let value: Double
        var prior: Double?
    }

    struct MacroInputs: Equatable, Sendable {
        var usCPI: MacroReading?
        var usCore: MacroReading?
        var eaCPI: MacroReading?
        var eaCore: MacroReading?
        var fedRate: MacroReading?
        var ecbRate: MacroReading?
        var nextUSCPI: String?
        var nextHICPFlash: String?
        var nextFOMC: String?
        var nextECB: String?
    }

    static let inflationTarget = 2.0
    static let rotatingAngles = ["rates", "core_gap", "us_vs_ea"]

    /// A fresh inflation print in the past week wins; otherwise the angle
    /// used least recently, so two Wednesdays in a row never match.
    static func macroAngle(day: String, history: DailyBoardHistory) -> String {
        if let weekAgo = DailyBoardDays.adding(-6, to: day) {
            let releases = BLSCPIReleaseCalendar.releaseDates + WorldMacroCalendar.hicpFlash
            let fresh = releases.contains { $0 >= weekAgo && $0 <= day }
            let covered = history.lastDay("inflation", topic: .macro).map { $0 >= weekAgo } ?? false
            if fresh, !covered {
                return "inflation"
            }
        }
        return rotatingAngles.enumerated().min { lhs, rhs in
            let left = history.lastDay(lhs.element, topic: .macro) ?? ""
            let right = history.lastDay(rhs.element, topic: .macro) ?? ""
            return left == right ? lhs.offset < rhs.offset : left < right
        }?.element ?? "rates"
    }

    static func macro(angle: String, _ inputs: MacroInputs) -> DailyBoardCandidate? {
        var sheet = DailyBoardFactSheet()
        sheet.rate("Inflation target of the Fed and the ECB", inflationTarget)
        switch angle {
        case "inflation":
            addPrint("US CPI inflation, year on year", inputs.usCPI, into: &sheet)
            addPrint("US core CPI inflation (ex food and energy), year on year", inputs.usCore, into: &sheet)
            addPrint("Euro-area HICP inflation, year on year", inputs.eaCPI, into: &sheet)
            addPrint("Euro-area core HICP inflation, year on year", inputs.eaCore, into: &sheet)
            sheet.text("Next US CPI release", inputs.nextUSCPI)
            sheet.text("Next euro-area inflation flash", inputs.nextHICPFlash)
            guard inputs.usCPI != nil || inputs.eaCPI != nil else { return nil }
        case "rates":
            guard let fed = inputs.fedRate, let ecb = inputs.ecbRate else { return nil }
            sheet.rate("Fed funds target, upper bound", fed.value)
            sheet.rate("ECB main refinancing rate", ecb.value)
            sheet.points("Fed rate minus ECB rate", fed.value - ecb.value)
            if let cpi = inputs.usCPI {
                sheet.rate("US CPI inflation (\(DailyBoardDays.monthName(cpi.period)))", cpi.value)
                sheet.points("US real policy rate (Fed rate minus CPI inflation)", fed.value - cpi.value)
            }
            if let hicp = inputs.eaCPI {
                sheet.rate("Euro-area HICP inflation (\(DailyBoardDays.monthName(hicp.period)))", hicp.value)
                sheet.points("Euro-area real policy rate (ECB rate minus HICP inflation)", ecb.value - hicp.value)
            }
            sheet.text("Next Fed decision", inputs.nextFOMC)
            sheet.text("Next ECB decision", inputs.nextECB)
        case "core_gap":
            guard let usCPI = inputs.usCPI, let usCore = inputs.usCore else { return nil }
            sheet.rate("US CPI inflation (\(DailyBoardDays.monthName(usCPI.period)))", usCPI.value)
            sheet.rate("US core CPI inflation (\(DailyBoardDays.monthName(usCore.period)))", usCore.value)
            sheet.points("US core minus headline", usCore.value - usCPI.value)
            if let eaCPI = inputs.eaCPI, let eaCore = inputs.eaCore {
                sheet.rate("Euro-area HICP inflation (\(DailyBoardDays.monthName(eaCPI.period)))", eaCPI.value)
                sheet.rate("Euro-area core HICP inflation (\(DailyBoardDays.monthName(eaCore.period)))", eaCore.value)
                sheet.points("Euro-area core minus headline", eaCore.value - eaCPI.value)
            }
            sheet.text("Next US CPI release", inputs.nextUSCPI)
        case "us_vs_ea":
            guard let usCPI = inputs.usCPI, let eaCPI = inputs.eaCPI else { return nil }
            sheet.rate("US CPI inflation (\(DailyBoardDays.monthName(usCPI.period)))", usCPI.value)
            sheet.rate("Euro-area HICP inflation (\(DailyBoardDays.monthName(eaCPI.period)))", eaCPI.value)
            sheet.points("US minus euro area, headline", usCPI.value - eaCPI.value)
            if let usCore = inputs.usCore, let eaCore = inputs.eaCore {
                sheet.rate("US core CPI inflation", usCore.value)
                sheet.rate("Euro-area core HICP inflation", eaCore.value)
                sheet.points("US minus euro area, core", usCore.value - eaCore.value)
            }
            if let fed = inputs.fedRate, let ecb = inputs.ecbRate {
                sheet.rate("Fed funds target, upper bound", fed.value)
                sheet.rate("ECB main refinancing rate", ecb.value)
            }
        default:
            return nil
        }
        guard sheet.figures >= minimumFigures else { return nil }
        return sheet.candidate(topic: .macro, name: angle, angle: angle)
    }

    private static func addPrint(_ label: String, _ reading: MacroReading?, into sheet: inout DailyBoardFactSheet) {
        guard let reading else { return }
        sheet.rate("\(label), \(DailyBoardDays.monthName(reading.period))", reading.value)
        sheet.rate("\(label), month before", reading.prior)
        if let prior = reading.prior {
            sheet.points("\(label), change from the month before", reading.value - prior)
        }
    }

    // MARK: Week in markets

    static func weekRecap(
        day: String,
        indexes: [(name: String, series: DailyBarSeries)],
        mag7: [DailyBarSeries]
    ) -> DailyBoardCandidate? {
        // The Monday of the week that just ended, for a Saturday or Sunday post.
        guard let weekday = DailyBoardRotation.weekday(day),
              let monday = DailyBoardDays.adding(-((weekday + 5) % 7), to: day)
        else { return nil }
        var sheet = DailyBoardFactSheet()
        sheet.text("Week", "the week starting \(DailyBoardDays.withWeekday(monday))")
        var moved = 0
        for (name, series) in indexes {
            guard let change = series.percentChange(sinceCloseBefore: monday), let last = series.last else { continue }
            sheet.percent("\(name), change on the week", change)
            sheet.price("\(name), close on \(last.date)", last.close)
            moved += 1
        }
        let weekly = mag7.compactMap { series in
            series.percentChange(sinceCloseBefore: monday).map { (series.symbol, $0) }
        }
        if let best = weekly.max(by: { $0.1 < $1.1 }), let worst = weekly.min(by: { $0.1 < $1.1 }), best.0 != worst.0 {
            sheet.percent("Best Mag 7 stock of the week, \(best.0)", best.1)
            sheet.percent("Worst Mag 7 stock of the week, \(worst.0)", worst.1)
        }
        guard moved >= 3 else { return nil }
        return sheet.candidate(topic: .weekRecap, name: "The week in markets")
    }

    // MARK: Week ahead

    struct Earnings: Equatable, Sendable {
        let symbol: String
        let date: String
        var hour: String?
        var epsEstimate: Double?
        var revenueEstimate: Double?
    }

    static func weekAhead(
        day _: String,
        events: [WorldMacroCalendar.Event],
        earnings: [Earnings],
        macro: MacroInputs
    ) -> DailyBoardCandidate? {
        var sheet = DailyBoardFactSheet()
        for event in events {
            sheet.text(DailyBoardDays.withWeekday(event.date), event.name)
        }
        let watched = earnings
            .filter { DailyBoardCatalog.earningsWatch.contains($0.symbol) }
            .sorted { ($0.date, $0.symbol) < ($1.date, $1.symbol) }
        for item in watched {
            let when = switch item.hour {
            case "bmo": " before the open"
            case "amc": " after the close"
            default: ""
            }
            sheet.text("\(item.symbol) earnings", DailyBoardDays.withWeekday(item.date) + when)
            sheet.number("\(item.symbol) consensus EPS estimate", item.epsEstimate)
            if let revenue = item.revenueEstimate, revenue > 0 {
                sheet.number("\(item.symbol) consensus revenue estimate, billions", revenue / 1_000_000_000, decimals: 1)
            }
        }
        guard events.count + watched.count >= 2 else { return nil }
        if let cpi = macro.usCPI {
            sheet.rate("Latest US CPI inflation (\(DailyBoardDays.monthName(cpi.period)))", cpi.value)
        }
        if let hicp = macro.eaCPI {
            sheet.rate("Latest euro-area HICP inflation (\(DailyBoardDays.monthName(hicp.period)))", hicp.value)
        }
        sheet.rate("Fed funds target, upper bound", macro.fedRate?.value)
        sheet.rate("ECB main refinancing rate", macro.ecbRate?.value)
        guard sheet.figures >= 3 else { return nil }
        return sheet.candidate(topic: .weekAhead, name: "The week ahead")
    }
}
