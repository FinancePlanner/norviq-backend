import Fluent
import FluentSQL
import Foundation
import NIOCore
import StockPlanShared
import Vapor

// MARK: - Identity

/// The account and board the daily post is published under. The account has
/// no password anyone knows, and sign-in, reset, block, and sanctions refuse it.
enum DailyBoardIdentity {
    static let username = "norviq"
    static let email = "daily-board@system.norviq.invalid"
    static let slug = "daily"
    static let description = "One post every day: a Mag 7 stock, a hot stock, inflation, an ETF, or the week in markets. Members can post here too."

    static func isSystemUsername(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == username
    }

    static func isSystemEmail(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == email
    }

    /// Creates the account and the Daily board the first time anyone asks.
    /// A username already owned by a person is left alone.
    @discardableResult
    static func ensure(on req: Request) async throws -> (userID: UUID, boardID: UUID) {
        let userID: UUID
        if let existing = try await User.query(on: req.db).filter(\.$username == username).first() {
            guard existing.email.lowercased() == email, let id = existing.id else {
                throw Abort(.conflict, reason: "The norviq username is taken.")
            }
            userID = id
        } else {
            let hash = try await req.password.async.hash(UUID().uuidString).get()
            let user = User(email: email, passwordHash: hash, username: username, isVerified: false, hadTrial: true)
            do {
                try await user.save(on: req.db)
            } catch let error as any DatabaseError where error.isConstraintFailure {
                // A concurrent request created the same account.
            }
            guard let created = try await User.query(on: req.db).filter(\.$username == username).first(),
                  created.email.lowercased() == email,
                  let id = created.id
            else {
                throw Abort(.conflict, reason: "The norviq username is taken.")
            }
            userID = id
        }

        if let board = try await Board.query(on: req.db).withDeleted().filter(\.$slug == slug).first() {
            if board.deletedAt != nil {
                try await board.restore(on: req.db)
            }
            // Boards created by an older build keep its wording until updated
            // here. A board someone else made under this slug is left alone.
            if board.creatorId == userID, board.description != description {
                board.description = description
                try await board.save(on: req.db)
            }
            return try (userID, board.requireID())
        }
        let board = Board(slug: slug, name: "Daily", description: description, creatorId: userID)
        do {
            try await board.create(on: req.db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // Created by the other replica.
        }
        guard let stored = try await Board.query(on: req.db).withDeleted().filter(\.$slug == slug).first() else {
            throw Abort(.internalServerError, reason: "Daily board was not created.")
        }
        if stored.deletedAt != nil {
            try await stored.restore(on: req.db)
        }
        return try (userID, stored.requireID())
    }
}

extension Application {
    private struct DailyBoardNewsKey: StorageKey {
        typealias Value = any NewsProvider
    }

    var dailyBoardNewsProvider: (any NewsProvider)? {
        get { storage[DailyBoardNewsKey.self] }
        set { storage[DailyBoardNewsKey.self] = newValue }
    }
}

// MARK: - When

enum DailyBoardSchedule {
    /// Weekend posts look back on the week or ahead to the next one, so they
    /// go out in the morning.
    static let weekendStart = 10 * 60

    /// The latest day whose window has opened: weekdays at 22:30 Lisbon,
    /// after the evening brief, and weekends at 10:00. A day missed until the
    /// next one opens is not written late.
    static func latestDueDate(now: Date) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MarketBriefSchedule.timeZone
        for offset in 0 ..< 2 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            if offset == 0 {
                let weekday = calendar.component(.weekday, from: day)
                let opens = (2 ... 6).contains(weekday) ? MarketBriefSchedule.eveningStart : weekendStart
                if MarketBriefSchedule.localMinutes(now) < opens {
                    continue
                }
            }
            return MarketBriefSchedule.localDate(day)
        }
        return nil
    }

    /// The Lisbon calendar date of an exchange timestamp, in seconds or
    /// milliseconds.
    static func sessionDate(_ timestamp: Double) -> String? {
        guard timestamp.isFinite, timestamp > 0 else { return nil }
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp
        return MarketBriefSchedule.localDate(Date(timeIntervalSince1970: seconds))
    }
}

// MARK: - Hot stock

enum DailyBoardFacts {
    /// A smaller move than this is not "hot".
    static let minimumStockMove = 1.0

    struct StockQuote: Equatable, Sendable {
        var symbol: String
        var price: Double
        var changePercent: Double
        var sessionDate: String
    }

    struct Headline: Equatable, Sendable {
        var title: String
        var url: String?
        var tickers: [String]
    }

    static func rankedTickers(_ headlines: [Headline], limit: Int = 5) -> [String] {
        var counts: [String: Int] = [:]
        for headline in headlines {
            for ticker in headline.tickers where isStockTicker(ticker) {
                counts[ticker, default: 0] += 1
            }
        }
        return counts.sorted { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value > rhs.value
            }
            return lhs.key < rhs.key
        }
        .prefix(limit)
        .map(\.key)
    }

    /// Tickers the news named, then the biggest large-cap movers, Mag 7 left
    /// to Monday.
    static func hotStockCandidates(headlines: [Headline], movers: [String], limit: Int = 12) -> [String] {
        let mag7 = Set(DailyBoardCatalog.mag7)
        var seen = Set<String>()
        return (rankedTickers(headlines, limit: 8) + movers.map { $0.uppercased() })
            .filter { isStockTicker($0) && !mag7.contains($0) && seen.insert($0).inserted }
            .prefix(limit)
            .map(\.self)
    }

    static func isStockTicker(_ symbol: String) -> Bool {
        let ticker = symbol.uppercased()
        guard !ticker.hasPrefix("^"), !ticker.contains("="), ticker != "GENERAL" else { return false }
        return ticker.wholeMatch(of: #/[A-Z]{1,5}(?:\.[A-Z]{1,2})?/#) != nil
    }

    /// The biggest same-day move of at least 1% among stocks the news named,
    /// Mag 7 left to Monday, with the headline that named it as the "why".
    static func hotStock(_ stocks: [StockQuote], headlines: [Headline], day: String) -> (StockQuote, Headline?)? {
        let mag7 = Set(DailyBoardCatalog.mag7)
        guard let best = stocks
            .filter({ stock in
                stock.sessionDate == day && !mag7.contains(stock.symbol.uppercased())
                    && stock.changePercent.isFinite && abs(stock.changePercent) >= minimumStockMove
            })
            .max(by: { abs($0.changePercent) < abs($1.changePercent) })
        else { return nil }
        let symbol = best.symbol.uppercased()
        return (best, headlines.first { $0.tickers.contains { $0.uppercased() == symbol } })
    }
}

// MARK: - Sources

/// Everything the daily post reads from outside the database. A protocol so
/// tests run without a network or a key. Every call degrades to nil or empty.
protocol DailyBoardSources: Sendable {
    func headlines(on req: Request) async -> [DailyBoardFacts.Headline]
    /// Today's biggest movers among the largest US companies, biggest move first.
    func largeCapMovers(on req: Request) async -> [String]
    func quote(_ symbol: String, on req: Request) async -> DailyBoardFacts.StockQuote?
    func metrics(_ symbol: String, on req: Request) async -> [String: Double]
    func earnings(from: String, to: String, symbol: String?, on req: Request) async -> [DailyBoardBuilders.Earnings]
    func bars(_ symbol: String, on req: Request) async -> DailyBarSeries?
    func macro(country: String, key: String, on req: Request) async -> DailyBoardBuilders.MacroReading?
}

struct LiveDailyBoardSources: DailyBoardSources {
    private static let yahoo = YahooDailyBarsProvider()

    func headlines(on req: Request) async -> [DailyBoardFacts.Headline] {
        guard let news = req.application.dailyBoardNewsProvider else { return [] }
        do {
            let items = try await news.fetchGeneral(on: req)
            let now = Date()
            return items
                .filter { now.timeIntervalSince($0.publishedAt) <= MarketBriefFacts.headlineMaxAge }
                .sorted { $0.publishedAt > $1.publishedAt }
                .prefix(MarketBriefFacts.maxHeadlines)
                .map { item in
                    let related = item.relatedSymbols.filter(DailyBoardFacts.isStockTicker)
                    let named = MarketBriefValidator.tickers([item.headline]).filter(DailyBoardFacts.isStockTicker)
                    return DailyBoardFacts.Headline(title: item.headline, url: item.url, tickers: related + named)
                }
        } catch {
            req.logger.warning("daily_board_post news_failed error=\(String(describing: error))")
            return []
        }
    }

    func largeCapMovers(on req: Request) async -> [String] {
        do {
            let heatmap = try await req.application.marketDataService.marketOverview(on: req).heatmap
            if !heatmap.isEmpty {
                return heatmap
                    .sorted { abs($0.changePct) > abs($1.changePct) }
                    .map(\.symbol)
            }
        } catch {
            req.logger.warning("daily_board_post movers_failed error=\(String(describing: error))")
        }
        // The overview runs on FMP, whose daily request cap is often spent by
        // evening. Quotes come from the main provider, so rank a fixed list.
        var quotes: [DailyBoardFacts.StockQuote] = []
        for symbol in DailyBoardCatalog.largeCaps {
            if let quote = await quote(symbol, on: req) {
                quotes.append(quote)
            }
        }
        return quotes
            .sorted { abs($0.changePercent) > abs($1.changePercent) }
            .map(\.symbol)
    }

    func quote(_ symbol: String, on req: Request) async -> DailyBoardFacts.StockQuote? {
        guard let quote = try? await req.application.marketDataService.quote(symbol: symbol, on: req),
              let change = quote.percentChange, change.isFinite,
              let session = DailyBoardSchedule.sessionDate(quote.timestamp)
        else { return nil }
        return DailyBoardFacts.StockQuote(
            symbol: quote.symbol, price: quote.currentPrice, changePercent: change, sessionDate: session
        )
    }

    func metrics(_ symbol: String, on req: Request) async -> [String: Double] {
        guard let response = try? await req.application.marketDataService.basicFinancials(symbol: symbol, on: req) else {
            return [:]
        }
        var values: [String: Double] = [:]
        for (key, value) in response.metric {
            if case let .number(number) = value, number.isFinite {
                values[key] = number
            }
        }
        return values
    }

    func earnings(from: String, to: String, symbol: String?, on req: Request) async -> [DailyBoardBuilders.Earnings] {
        do {
            let rows = try await req.application.earningsService.getCalendar(
                query: EarningsQueryRequest(from: from, to: to, symbol: symbol),
                on: req
            )
            return rows.compactMap { row in
                guard let symbol = row.symbol, let date = row.date else { return nil }
                return DailyBoardBuilders.Earnings(
                    symbol: symbol.uppercased(),
                    date: date,
                    hour: row.hour,
                    epsEstimate: row.epsEstimate,
                    revenueEstimate: row.revenueEstimate
                )
            }
        } catch {
            req.logger.warning("daily_board_post earnings_failed error=\(String(describing: error))")
            return []
        }
    }

    func bars(_ symbol: String, on req: Request) async -> DailyBarSeries? {
        await Self.yahoo.series(symbol: symbol, on: req)
    }

    /// The latest period and the one before it, within the last half year.
    func macro(country: String, key: String, on req: Request) async -> DailyBoardBuilders.MacroReading? {
        let since = DailyBoardDays.adding(-190, to: MarketBriefSchedule.localDate(Date()))
        guard let points = try? await req.application.macroRepository.series(
            country: country, seriesKey: key, from: since, to: nil, limit: 2, on: req.db
        ), let latest = points.last
        else { return nil }
        let prior = points.count > 1 ? points[points.count - 2].value : nil
        return DailyBoardBuilders.MacroReading(period: latest.periodDate, value: latest.value, prior: prior)
    }
}

// MARK: - Style

enum DailyBoardStyle {
    /// Phrases that mark a text as machine-written. Shown to the model and
    /// enforced by the validator, from this one list.
    static let bannedPhrases = [
        "delve", "landscape", "navigate", "navigating", "in today's", "dive in", "dive into", "deep dive",
        "buckle up", "rollercoaster", "roller coaster", "game-changer", "game changer", "only time will tell",
        "it's worth noting", "it is worth noting", "remains to be seen", "testament", "tapestry",
        "unprecedented", "in conclusion", "let's", "what do you think",
    ]

    /// Wording that tells the reader what to do with their money.
    static let advicePatterns = [
        #"\b(you|investors|traders|readers|members)\s+(should|must|need to|ought to|may want to|might want to)\b"#,
        #"\b(consider|start|time to)\s+(buying|selling|adding|trimming|accumulating|shorting)\b"#,
        #"\b(buy|sell)\s+(now|the dip)\b"#,
        #"\bthis is a (buy|sell)\b"#,
    ]

    static var system: String {
        """
        You write the daily post for the Norviq community board, read by retail investors in Europe and the US. \
        One topic per post, explained well enough that members want to argue about it in the comments.

        Use only the facts in the user message. Every number you write must appear in the facts, with the same \
        precision. Never compute a new number, never round differently, and never add a price, percentage, date \
        or ticker that is not listed. Write dates as words if you like (Monday, October 26).

        Return JSON with keys title and body.
        Title: under 110 characters. State the main fact, with its number when there is one. No question, \
        no clickbait.
        Body: 120 to 220 words of plain text in 3 or 4 short paragraphs separated by a blank line.
        1. What happened, with the key figures.
        2. Context: two or three more figures from the facts that put it in perspective.
        3. Why it could matter, as a possibility, not a prediction.
        4. One specific question members can disagree about, tied to a figure in the post. For example: \
        "Is 31.4x trailing earnings still cheap for a company growing this fast?" Never a generic \
        "What do you think?".

        Write like a sharp analyst talking to peers: concrete, plain words, short sentences. No advice: never \
        tell the reader to buy, sell, hold or consider anything. No markdown, hashtags, emoji, exclamation marks \
        or em dashes. Do not use these words or phrases: \(bannedPhrases.joined(separator: ", ")).
        """
    }

    static func describe(_ candidate: DailyBoardCandidate) -> String {
        switch candidate.topic {
        case .mag7:
            "\(candidate.name), one of the Magnificent Seven: what its recent move and valuation say"
        case .stock:
            "\(candidate.name), the stock the news named most today, and why it moved"
        case .etf:
            "\(candidate.name), a widely held ETF: what it tracks, what it costs and how it has done"
        case .weekRecap:
            "how the major stock indexes moved over the week that just ended"
        case .weekAhead:
            "the central-bank decisions, inflation releases and big earnings reports due in the next seven days"
        case .macro:
            switch candidate.angle {
            case "inflation": "the latest inflation figures for the US and the euro area"
            case "rates": "Fed and ECB policy rates measured against inflation"
            case "core_gap": "the gap between core and headline inflation"
            default: "inflation in the US compared with the euro area"
            }
        case .index, .news:
            candidate.name
        }
    }

    static func prompt(for candidate: DailyBoardCandidate, day: String) -> String {
        let facts = candidate.facts.map { "- \($0.label): \($0.value)" }.joined(separator: "\n")
        return """
        Post date: \(DailyBoardDays.withWeekday(day))
        Topic: \(describe(candidate))
        Facts:
        \(facts)
        """
    }
}

enum DailyBoardValidator {
    static let disclosure = "Written by Norviq AI from the latest market data. Not financial advice."
    static let maxTitleLength = 120
    static let maxBodyLength = 1600
    static let wordRange = 80 ... 260
    static let minimumFigures = 3

    enum Rejection: Error, Equatable, CustomStringConvertible {
        case title
        case length(words: Int)
        case figures(Int)
        case ungrounded
        case phrase(String)
        case advice(String)
        case noQuestion

        /// Read back to the model when it gets a second try.
        var description: String {
            switch self {
            case .title: "the title was empty, too long, or had an exclamation mark"
            case let .length(words): "the body was \(words) words; it must be 120 to 220"
            case let .figures(count): "the body cited only \(count) figures from the facts; cite at least 3"
            case .ungrounded: "it cited a number that is not in the facts, or rounded one differently"
            case let .phrase(phrase): "it used \"\(phrase)\", which is not allowed"
            case let .advice(text): "\"\(text)\" reads as investment advice"
            case .noQuestion: "the last paragraph must end with one specific question for members"
            }
        }
    }

    /// The cleaned title and the body with the disclosure appended, or why
    /// the draft cannot run.
    static func check(
        title rawTitle: String,
        body rawBody: String,
        grounded: [Double]
    ) -> Result<(title: String, body: String), Rejection> {
        let title = rawTitle.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let body = clean(rawBody)
        guard (3 ... maxTitleLength).contains(title.count), !title.contains("!") else { return .failure(.title) }
        let words = body.split(whereSeparator: \.isWhitespace).count
        guard wordRange.contains(words), body.count <= maxBodyLength else { return .failure(.length(words: words)) }
        let text = (title + "\n" + body).replacingOccurrences(of: "\u{2019}", with: "'")
        if let phrase = bannedPhrase(in: text) {
            return .failure(.phrase(phrase))
        }
        if let advice = advice(in: text) {
            return .failure(.advice(advice))
        }
        let figures = MarketBriefNumbers.tokens(in: body).count
        guard figures >= minimumFigures else { return .failure(.figures(figures)) }
        guard MarketBriefValidator.isGrounded(title + "\n" + body, grounded: grounded) else {
            return .failure(.ungrounded)
        }
        let last = body.components(separatedBy: "\n\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard last?.contains("?") == true else { return .failure(.noQuestion) }
        return .success((title, body + "\n\n" + disclosure))
    }

    static func accept(title: String, body: String, grounded: [Double]) -> (title: String, body: String)? {
        try? check(title: title, body: body, grounded: grounded).get()
    }

    /// Dashes become commas rather than a rejection; blank lines collapse to
    /// one so paragraphs survive.
    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: " \u{2014} ", with: ", ")
            .replacingOccurrences(of: "\u{2014}", with: ", ")
            .replacingOccurrences(of: " \u{2013} ", with: ", ")
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text
    }

    private static func bannedPhrase(in text: String) -> String? {
        if text.contains("!") {
            return "!"
        }
        if text.unicodeScalars.contains(where: \.properties.isEmojiPresentation) {
            return "emoji"
        }
        return DailyBoardStyle.bannedPhrases.first { phrase in
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: phrase)
            return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func advice(in text: String) -> String? {
        for pattern in DailyBoardStyle.advicePatterns {
            if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                return String(text[range])
            }
        }
        return nil
    }
}

// MARK: - Model

protocol DailyBoardWriting: Sendable {
    func draft(prompt: String, on req: Request) async throws -> (title: String, body: String)
}

struct OpenAIDailyBoardWriter: DailyBoardWriting {
    func draft(prompt: String, on req: Request) async throws -> (title: String, body: String) {
        let reply = try await req.application.openAIChatClient.chat(
            messages: [
                OpenAIMessage(role: "system", content: DailyBoardStyle.system),
                OpenAIMessage(role: "user", content: prompt),
            ],
            tools: [],
            responseFormat: "json_object",
            on: req
        )
        guard let content = reply.content else { throw Abort(.badGateway, reason: "The daily post draft was empty.") }
        return try Self.parse(content)
    }

    static func parse(_ content: String) throws -> (title: String, body: String) {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        }
        struct Draft: Decodable { let title: String; let body: String }
        let draft = try JSONDecoder().decode(Draft.self, from: Data(text.utf8))
        return (draft.title, draft.body)
    }
}

// MARK: - Publish

enum DailyBoardOutcome: Equatable, CustomStringConvertible {
    case alreadyRun(status: String)
    case skipped(reason: String)
    case published(topic: DailyBoardTopic)

    var description: String {
        switch self {
        case let .alreadyRun(status): "already \(status)"
        case let .skipped(reason): "skipped (\(reason))"
        case let .published(topic): "published \(topic.rawValue)"
        }
    }
}

enum DailyBoardPostError: Error, CustomStringConvertible {
    /// Both drafts failed the validator. Thrown, not skipped, so the job asks
    /// again on its next tick.
    case rejected(DailyBoardValidator.Rejection)

    var description: String {
        switch self {
        case let .rejected(reason): "draft rejected: \(reason)"
        }
    }
}

enum DailyBoardPublisher {
    /// One draft, and one more with the first one's fault named.
    static let draftsPerAttempt = 2

    /// Builds the day's facts, asks the model, and writes one post. Skips the
    /// day when no topic has enough data. A second call on the same date
    /// does nothing.
    @discardableResult
    static func run(
        tradingDate: String,
        writer: any DailyBoardWriting,
        sources: any DailyBoardSources = LiveDailyBoardSources(),
        topic: DailyBoardTopic? = nil,
        on req: Request
    ) async throws -> DailyBoardOutcome {
        if let run = try await DailyBoardPostRun.find(tradingDate, on: req.db) {
            return .alreadyRun(status: run.status)
        }
        guard let candidate = try await compose(day: tradingDate, topic: topic, sources: sources, on: req) else {
            try await skip(tradingDate: tradingDate, topic: nil, on: req)
            return .skipped(reason: "no topic had enough data")
        }
        let accepted = try await write(candidate, day: tradingDate, writer: writer, on: req)
        return try await insert(
            tradingDate: tradingDate,
            candidate: candidate,
            title: accepted.title,
            body: accepted.body,
            on: req
        )
    }

    /// The first topic in the day's rotation, or the one asked for, that has
    /// enough facts behind it.
    static func compose(
        day: String,
        topic: DailyBoardTopic?,
        sources: any DailyBoardSources,
        on req: Request
    ) async throws -> DailyBoardCandidate? {
        let history = try await history(before: day, on: req.db)
        for next in topic.map({ [$0] }) ?? DailyBoardRotation.topics(for: day) {
            if let candidate = await candidate(next, day: day, history: history, sources: sources, on: req) {
                return candidate
            }
            req.logger.info("daily_board_post topic_unavailable topic=\(next.rawValue) date=\(day)")
        }
        return nil
    }

    /// Drafts until the validator accepts, telling the model what was wrong
    /// the first time.
    static func write(
        _ candidate: DailyBoardCandidate,
        day: String,
        writer: any DailyBoardWriting,
        on req: Request
    ) async throws -> (title: String, body: String) {
        let prompt = DailyBoardStyle.prompt(for: candidate, day: day)
        var rejection: DailyBoardValidator.Rejection?
        for _ in 0 ..< draftsPerAttempt {
            let text = rejection.map {
                prompt + "\n\nYour previous draft was rejected because \($0). Write it again and fix that."
            } ?? prompt
            let draft = try await writer.draft(prompt: text, on: req)
            switch DailyBoardValidator.check(title: draft.title, body: draft.body, grounded: candidate.grounded) {
            case let .success(accepted):
                return accepted
            case let .failure(reason):
                req.logger.info("daily_board_post draft_rejected date=\(day) reason=\(reason)")
                rejection = reason
            }
        }
        throw DailyBoardPostError.rejected(rejection ?? .ungrounded)
    }

    static func candidate(
        _ topic: DailyBoardTopic,
        day: String,
        history: DailyBoardHistory,
        sources: any DailyBoardSources,
        on req: Request
    ) async -> DailyBoardCandidate? {
        switch topic {
        case .mag7:
            var snapshots: [DailyBoardBuilders.StockSnapshot] = []
            for symbol in DailyBoardCatalog.mag7 {
                guard let quote = await sources.quote(symbol, on: req) else { continue }
                await snapshots.append(snapshot(quote, metrics: sources.metrics(symbol, on: req)))
            }
            guard var pick = DailyBoardBuilders.pickMag7(snapshots, history: history) else { return nil }
            pick.nextEarnings = await nextEarnings(pick.symbol, day: day, sources: sources, on: req)
            return DailyBoardBuilders.stock(pick, topic: .mag7)

        case .stock:
            let headlines = await sources.headlines(on: req)
            var quotes: [DailyBoardFacts.StockQuote] = []
            // General news rarely tags tickers, so the day's biggest large-cap
            // movers are candidates too.
            let movers = await sources.largeCapMovers(on: req)
            for symbol in DailyBoardFacts.hotStockCandidates(headlines: headlines, movers: movers) {
                if let quote = await sources.quote(symbol, on: req) {
                    quotes.append(quote)
                }
            }
            guard let (best, story) = DailyBoardFacts.hotStock(quotes, headlines: headlines, day: day) else { return nil }
            var pick = await snapshot(best, metrics: sources.metrics(best.symbol, on: req))
            pick.headline = story
            pick.nextEarnings = await nextEarnings(best.symbol, day: day, sources: sources, on: req)
            return DailyBoardBuilders.stock(pick, topic: .stock)

        case .etf:
            for fund in DailyBoardBuilders.etfOrder(history: history).prefix(3) {
                if let series = await sources.bars(fund.symbol, on: req),
                   let candidate = DailyBoardBuilders.etf(fund, series: series)
                {
                    return candidate
                }
            }
            return nil

        case .macro:
            let inputs = await macroInputs(day: day, sources: sources, on: req)
            let preferred = DailyBoardBuilders.macroAngle(day: day, history: history)
            let angles = [preferred] + (["inflation"] + DailyBoardBuilders.rotatingAngles).filter { $0 != preferred }
            for angle in angles {
                if let candidate = DailyBoardBuilders.macro(angle: angle, inputs) {
                    return candidate
                }
            }
            return nil

        case .weekRecap:
            var indexes: [(name: String, series: DailyBarSeries)] = []
            for index in DailyBoardCatalog.recapIndexes {
                if let series = await sources.bars(index.symbol, on: req) {
                    indexes.append((index.name, series))
                }
            }
            var mag7: [DailyBarSeries] = []
            for symbol in DailyBoardCatalog.mag7 {
                if let series = await sources.bars(symbol, on: req) {
                    mag7.append(series)
                }
            }
            return DailyBoardBuilders.weekRecap(day: day, indexes: indexes, mag7: mag7)

        case .weekAhead:
            guard let from = DailyBoardDays.adding(1, to: day), let through = DailyBoardDays.adding(7, to: day) else {
                return nil
            }
            return await DailyBoardBuilders.weekAhead(
                day: day,
                events: WorldMacroCalendar.events(from: from, through: through),
                earnings: sources.earnings(from: from, to: through, symbol: nil, on: req),
                macro: macroInputs(day: day, sources: sources, on: req)
            )

        case .index, .news:
            return nil
        }
    }

    private static func snapshot(
        _ quote: DailyBoardFacts.StockQuote,
        metrics: [String: Double]
    ) -> DailyBoardBuilders.StockSnapshot {
        DailyBoardBuilders.StockSnapshot(
            symbol: quote.symbol.uppercased(),
            price: quote.price,
            changePercent: quote.changePercent,
            sessionDate: quote.sessionDate,
            metrics: metrics
        )
    }

    private static func nextEarnings(
        _ symbol: String,
        day: String,
        sources: any DailyBoardSources,
        on req: Request
    ) async -> String? {
        guard let from = DailyBoardDays.adding(1, to: day), let to = DailyBoardDays.adding(30, to: day) else { return nil }
        let dates = await sources.earnings(from: from, to: to, symbol: symbol, on: req)
            .filter { $0.symbol == symbol.uppercased() && $0.date >= from }
            .map(\.date)
        return dates.min().map(DailyBoardDays.withWeekday)
    }

    static func macroInputs(
        day: String,
        sources: any DailyBoardSources,
        on req: Request
    ) async -> DailyBoardBuilders.MacroInputs {
        func next(_ dates: [String]) -> String? {
            dates.filter { $0 > day }.min().map(DailyBoardDays.withWeekday)
        }
        // The macro tables store MacroCountry raw values ("US", "EA").
        let us = MacroCountry.us.rawValue, ea = MacroCountry.ea.rawValue
        return await DailyBoardBuilders.MacroInputs(
            usCPI: sources.macro(country: us, key: MacroSeriesKey.headlineCPI.rawValue, on: req),
            usCore: sources.macro(country: us, key: MacroSeriesKey.coreCPI.rawValue, on: req),
            eaCPI: sources.macro(country: ea, key: MacroSeriesKey.headlineCPI.rawValue, on: req),
            eaCore: sources.macro(country: ea, key: MacroSeriesKey.coreCPI.rawValue, on: req),
            fedRate: sources.macro(country: us, key: MacroSeriesKey.policyRate.rawValue, on: req),
            ecbRate: sources.macro(country: ea, key: MacroSeriesKey.policyRate.rawValue, on: req),
            nextUSCPI: next(BLSCPIReleaseCalendar.releaseDates),
            nextHICPFlash: next(WorldMacroCalendar.hicpFlash),
            nextFOMC: next(FOMCCalendar.meetings.map(\.endDate)),
            nextECB: next(WorldMacroCalendar.ecbDecisions)
        )
    }

    /// The last 60 daily posts before `day`, newest first.
    static func history(before day: String, on db: any Database) async throws -> DailyBoardHistory {
        let posts = try await BoardPost.query(on: db)
            .filter(\.$aiGenerated == true)
            .filter(\.$tradingDate < day)
            .sort(\.$tradingDate, .descending)
            .limit(60)
            .all()
        return DailyBoardHistory(entries: posts.compactMap { post in
            guard let date = post.tradingDate else { return nil }
            return DailyBoardHistory.Entry(
                day: date,
                topic: post.aiTopic.flatMap(DailyBoardTopic.init(rawValue:)),
                tags: post.tags
            )
        })
    }

    static func skip(tradingDate: String, topic: DailyBoardTopic?, on req: Request) async throws {
        try await writeRun(tradingDate: tradingDate, status: "skipped", postID: nil, topic: topic?.rawValue, on: req.db)
    }

    /// Inserts the post and the run row. Used by the job and by tests that
    /// already have a validated draft.
    @discardableResult
    static func insert(
        tradingDate: String,
        candidate: DailyBoardCandidate,
        title: String,
        body: String,
        on req: Request
    ) async throws -> DailyBoardOutcome {
        if let run = try await DailyBoardPostRun.find(tradingDate, on: req.db) {
            return .alreadyRun(status: run.status)
        }
        let identity = try await DailyBoardIdentity.ensure(on: req)
        let now = Date()
        var url: String?
        var domain: String?
        var kind = BoardPostKind.text.rawValue
        if candidate.topic == .news {
            do {
                let link = try CommunityValidation.link(candidate.url)
                url = link.url
                domain = link.domain
                kind = BoardPostKind.link.rawValue
            } catch {
                try await skip(tradingDate: tradingDate, topic: candidate.topic, on: req)
                return .skipped(reason: "headline link rejected")
            }
        }

        let post = BoardPost(
            boardId: identity.boardID,
            authorId: identity.userID,
            kind: kind,
            title: title,
            url: url,
            domain: domain,
            body: body,
            tags: candidate.tags,
            now: now
        )
        post.aiGenerated = true
        post.aiTopic = candidate.topic.rawValue
        post.tradingDate = tradingDate

        try await req.db.transaction { tx in
            try await post.create(on: tx)
            guard let sql = tx as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Boards need a SQL database")
            }
            try await sql.raw("""
            UPDATE boards SET post_count = post_count + 1, last_activity_at = \(bind: now) WHERE id = \(bind: identity.boardID)
            """).run()
            try await writeRun(
                tradingDate: tradingDate,
                status: "published",
                postID: post.requireID(),
                topic: candidate.topic.rawValue,
                on: tx
            )
        }
        return .published(topic: candidate.topic)
    }

    /// Clears a date so it can be written again: drops the run row and
    /// soft-deletes that date's AI post, if one is still up.
    static func reset(tradingDate: String, on db: any Database) async throws {
        try await db.transaction { tx in
            let posts = try await BoardPost.query(on: tx)
                .filter(\.$aiGenerated == true)
                .filter(\.$tradingDate == tradingDate)
                .all()
            for post in posts {
                try await post.delete(on: tx)
                guard let sql = tx as? any SQLDatabase else {
                    throw Abort(.internalServerError, reason: "Boards need a SQL database")
                }
                try await sql.raw("""
                UPDATE boards SET post_count = GREATEST(post_count - 1, 0) WHERE id = \(bind: post.boardId)
                """).run()
            }
            try await DailyBoardPostRun.query(on: tx).filter(\.$id == tradingDate).delete()
        }
    }

    private static func writeRun(
        tradingDate: String,
        status: String,
        postID: UUID?,
        topic: String?,
        on db: any Database
    ) async throws {
        if try await DailyBoardPostRun.find(tradingDate, on: db) != nil {
            return
        }
        let run = DailyBoardPostRun()
        run.id = tradingDate
        run.status = status
        run.postId = postID
        run.topic = topic
        do {
            try await run.create(on: db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            return
        }
    }
}

// MARK: - Job

/// Publishes one Daily board post after the evening market brief, or after
/// that window has closed. One leader replica, one model call per date.
final class DailyBoardPostJob: LifecycleHandler, @unchecked Sendable {
    static let maxAttempts = 3

    private let state = BackgroundJobState()
    private let attempts = DailyBoardAttempts()

    func didBoot(_ app: Application) throws {
        guard app.environment != .testing else { return }
        guard AIProviderConfiguration.load().isConfigured else {
            app.logger.notice("daily_board_post disabled reason=missing_ai_provider_key")
            return
        }
        let scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .seconds(90),
            delay: .seconds(300)
        ) { _ in
            guard self.state.begin() else { return }
            let task = Task {
                defer { self.state.finish() }
                await self.tick(app, now: Date())
            }
            self.state.track(task: task)
        }
        state.set(scheduled: scheduled)
    }

    func shutdown(_: Application) {
        state.stopAcceptingRuns()
    }

    func shutdownAsync(_: Application) async {
        await state.stopAndDrain()
    }

    func tick(_ app: Application, now: Date) async {
        guard let tradingDate = DailyBoardSchedule.latestDueDate(now: now) else { return }
        await JobLock.runAsLeader(app, name: "daily_board_post") {
            let req = Request(application: app, on: app.eventLoopGroup.next())
            do {
                if try await DailyBoardPostRun.find(tradingDate, on: app.db) != nil {
                    return
                }
                if await self.waitingForBrief(tradingDate, now: now, on: req) {
                    return
                }
                if self.attempts.failures(for: tradingDate) >= Self.maxAttempts {
                    try await DailyBoardPublisher.skip(tradingDate: tradingDate, topic: nil, on: req)
                    return
                }
                try await DailyBoardPublisher.run(tradingDate: tradingDate, writer: OpenAIDailyBoardWriter(), on: req)
            } catch {
                let count = self.attempts.recordFailure(for: tradingDate)
                app.logger.error(
                    "daily_board_post failed date=\(tradingDate) attempt=\(count)/\(Self.maxAttempts) error=\(String(describing: error))"
                )
            }
        }
    }

    /// During the evening window, wait until that date's brief exists so the
    /// post is not written from the morning's numbers. After midnight the
    /// brief is no longer required.
    private func waitingForBrief(_ tradingDate: String, now: Date, on req: Request) async -> Bool {
        guard let due = MarketBriefSchedule.dueSlot(now: now), due.slot == .evening, due.tradingDate == tradingDate else {
            return false
        }
        do {
            let brief = try await req.application.marketBriefRepository.find(
                tradingDate: tradingDate, slot: .evening, language: "en", on: req.db
            )
            return brief == nil
        } catch {
            req.logger.warning("daily_board_post brief_lookup_failed error=\(String(describing: error))")
            return true
        }
    }
}

private final class DailyBoardAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func failures(for date: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[date] ?? 0
    }

    @discardableResult
    func recordFailure(for date: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let next = (counts[date] ?? 0) + 1
        counts[date] = next
        return next
    }
}
