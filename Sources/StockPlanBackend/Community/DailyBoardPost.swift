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
            return try (userID, board.requireID())
        }
        let board = Board(
            slug: slug,
            name: "Daily",
            description: "One post each trading day about a stock, an index, or the news. Members can post here too.",
            creatorId: userID
        )
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
    /// The latest weekday whose evening window has opened. Monday morning is
    /// still Friday. Before 22:30 Lisbon, today is not due yet.
    static func latestDueDate(now: Date) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MarketBriefSchedule.timeZone
        for offset in 0 ..< 8 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            let weekday = calendar.component(.weekday, from: day)
            guard (2 ... 6).contains(weekday) else { continue }
            if offset == 0, MarketBriefSchedule.localMinutes(now) < MarketBriefSchedule.eveningStart {
                continue
            }
            return MarketBriefSchedule.localDate(day)
        }
        return nil
    }

    /// A quote counts for `tradingDate` when its exchange timestamp falls on
    /// that Lisbon calendar date.
    static func isOnTradingDate(_ timestamp: Double, tradingDate: String) -> Bool {
        guard timestamp.isFinite, timestamp > 0 else { return false }
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp
        return MarketBriefSchedule.localDate(Date(timeIntervalSince1970: seconds)) == tradingDate
    }
}

// MARK: - What to write about

enum DailyBoardTopic: String, Equatable, Sendable {
    case stock
    case index
    case news
}

struct DailyBoardCandidate: Equatable, Sendable {
    var topic: DailyBoardTopic
    var name: String
    var symbol: String
    var price: Double?
    var changePercent: Double?
    var url: String?
    /// Set for a news post so numbers in the headline stay grounded.
    var headline: String?
}

struct DailyBoardSignals: Equatable, Sendable {
    var stock: DailyBoardCandidate?
    var index: DailyBoardCandidate?
    var news: DailyBoardCandidate?
}

enum DailyBoardFacts {
    /// A smaller move than this is not "hot" and must not crowd out the index.
    static let minimumStockMove = 1.0

    static let eveningIndexes: Set<String> = ["^GSPC", "^NDX", "^DJI", "^GDAXI", "^FCHI", "^STOXX50E"]

    /// Index symbol to the fund we quote separately. The post cites the fund
    /// only when that quote is from the trading day.
    static let fundForIndex: [String: String] = [
        "^GSPC": "SPY",
        "^NDX": "QQQ",
        "^STOXX50E": "EXW1.DE",
    ]

    struct StockQuote: Equatable, Sendable {
        var symbol: String
        var price: Double
        var changePercent: Double
        var onTradingDate: Bool
    }

    struct IndexMove: Equatable, Sendable {
        var symbol: String
        var name: String
        var price: Double
        var changePercent: Double
    }

    struct FundQuote: Equatable, Sendable {
        var symbol: String
        var price: Double
        var changePercent: Double
        var onTradingDate: Bool
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

    static func isStockTicker(_ symbol: String) -> Bool {
        let ticker = symbol.uppercased()
        guard !ticker.hasPrefix("^"), !ticker.contains("="), ticker != "GENERAL" else { return false }
        return ticker.wholeMatch(of: #/[A-Z]{1,5}(?:\.[A-Z]{1,2})?/#) != nil
    }

    static func signals(
        stocks: [StockQuote],
        indexes: [IndexMove],
        funds: [String: FundQuote],
        headlines: [Headline]
    ) -> DailyBoardSignals {
        DailyBoardSignals(
            stock: stockCandidate(stocks, headlines: headlines),
            index: indexCandidate(indexes, funds: funds),
            news: newsCandidate(headlines)
        )
    }

    static func choose(_ signals: DailyBoardSignals, yesterday: DailyBoardTopic?) -> DailyBoardCandidate? {
        let ordered = [signals.stock, signals.index, signals.news].compactMap(\.self)
        let fresh = ordered.filter { $0.topic != yesterday }
        return (fresh.isEmpty ? ordered : fresh).first
    }

    static func grounded(_ candidate: DailyBoardCandidate) -> [Double] {
        var numbers: [Double] = []
        if let price = candidate.price, price.isFinite {
            numbers.append(price)
        }
        if let change = candidate.changePercent, change.isFinite {
            numbers.append(contentsOf: [change, abs(change)])
        }
        if let headline = candidate.headline {
            numbers.append(contentsOf: MarketBriefNumbers.tokens(in: headline).flatMap(\.readings))
        }
        return numbers
    }

    static func prompt(for candidate: DailyBoardCandidate) -> String {
        var facts: [String: String] = ["name": candidate.name]
        if !candidate.symbol.isEmpty {
            facts["symbol"] = candidate.symbol
        }
        if let price = candidate.price {
            facts["price"] = format(price)
        }
        if let change = candidate.changePercent {
            facts["changePercent"] = format(change)
        }
        if let headline = candidate.headline {
            facts["headline"] = headline
        }
        let encoded = facts.keys.sorted().map { "\($0): \(facts[$0] ?? "")" }.joined(separator: "\n")
        return """
        Topic: \(candidate.topic.rawValue)
        \(encoded)
        """
    }

    /// The headline that named the ticker rides along, so the post can say
    /// why it moved instead of only that it did.
    private static func stockCandidate(_ stocks: [StockQuote], headlines: [Headline]) -> DailyBoardCandidate? {
        guard let best = stocks
            .filter({ $0.onTradingDate && $0.changePercent.isFinite && abs($0.changePercent) >= minimumStockMove })
            .max(by: { abs($0.changePercent) < abs($1.changePercent) })
        else { return nil }
        let symbol = best.symbol.uppercased()
        let story = headlines.first { $0.tickers.contains { $0.uppercased() == symbol } }
        return DailyBoardCandidate(
            topic: .stock,
            name: best.symbol,
            symbol: best.symbol,
            price: round2(best.price),
            changePercent: round2(best.changePercent),
            url: nil,
            headline: story?.title
        )
    }

    private static func indexCandidate(_ indexes: [IndexMove], funds: [String: FundQuote]) -> DailyBoardCandidate? {
        guard let best = indexes
            .filter({ eveningIndexes.contains($0.symbol) && $0.changePercent.isFinite })
            .max(by: { abs($0.changePercent) < abs($1.changePercent) })
        else { return nil }
        if let mapped = fundForIndex[best.symbol],
           let fund = funds[mapped],
           fund.onTradingDate,
           fund.changePercent.isFinite
        {
            return DailyBoardCandidate(
                topic: .index,
                name: fundName(mapped),
                symbol: mapped,
                price: round2(fund.price),
                changePercent: round2(fund.changePercent),
                url: nil,
                headline: nil
            )
        }
        return DailyBoardCandidate(
            topic: .index,
            name: best.name,
            symbol: best.symbol,
            price: round2(best.price),
            changePercent: round2(best.changePercent),
            url: nil,
            headline: nil
        )
    }

    private static func newsCandidate(_ headlines: [Headline]) -> DailyBoardCandidate? {
        guard let lead = headlines.first(where: { item in
            !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && item.url?.hasPrefix("https://") == true
        }) else { return nil }
        return DailyBoardCandidate(
            topic: .news,
            name: lead.title,
            symbol: "",
            price: nil,
            changePercent: nil,
            url: lead.url,
            headline: lead.title
        )
    }

    private static func fundName(_ symbol: String) -> String {
        switch symbol {
        case "SPY": "SPY, the S&P 500 ETF"
        case "QQQ": "QQQ, the Nasdaq 100 ETF"
        case "EXW1.DE": "EXW1.DE, the Euro Stoxx 50 ETF"
        default: symbol
        }
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded(.toNearestOrAwayFromZero) / 100
    }

    private static func format(_ value: Double) -> String {
        let rounded = round2(value)
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), rounded)
    }
}

enum DailyBoardValidator {
    static let disclosure = "Written by Norviq AI from today's market data. Not financial advice."
    static let maxBodyLength = 600

    /// Returns the title and the body with the disclosure already appended.
    /// Nil when the draft invents a number or ignores the length limits.
    static func accept(title rawTitle: String, body rawBody: String, grounded: [Double]) -> (title: String, body: String)? {
        let title = rawTitle.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3 ... CommunityValidation.maxTitleLength).contains(title.count),
              !body.isEmpty,
              body.count <= maxBodyLength
        else { return nil }
        guard MarketBriefValidator.isGrounded(title + "\n" + body, grounded: grounded) else { return nil }
        return (title, body + "\n\n" + disclosure)
    }
}

// MARK: - Model

protocol DailyBoardWriting: Sendable {
    func draft(prompt: String, on req: Request) async throws -> (title: String, body: String)
}

struct OpenAIDailyBoardWriter: DailyBoardWriting {
    static let system = """
    You write one short English post for a finance community board. \
    Use only the facts in the user message. Do not add a price, percentage, date, or ticker that is not listed. \
    Return JSON with keys title and body. The title is under 120 characters. \
    The body is two to four sentences and under 600 characters. \
    No disclaimer, no markdown, no hashtags.
    """

    func draft(prompt: String, on req: Request) async throws -> (title: String, body: String) {
        let reply = try await req.application.openAIChatClient.chat(
            messages: [
                OpenAIMessage(role: "system", content: Self.system),
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
    /// The draft cited a number that was not fetched. Thrown, not skipped, so
    /// the job asks again with the same prompt on its next tick.
    case ungrounded

    var description: String {
        "draft cited a number that is not in the facts"
    }
}

enum DailyBoardPublisher {
    private static let quotes = YahooChartQuoteProvider()

    /// Fetches facts, asks the model, and writes one post or a skip row.
    /// A second call on the same date does nothing.
    @discardableResult
    static func run(tradingDate: String, writer: any DailyBoardWriting, on req: Request) async throws -> DailyBoardOutcome {
        if let run = try await DailyBoardPostRun.find(tradingDate, on: req.db) {
            return .alreadyRun(status: run.status)
        }
        let signals = try await gather(tradingDate: tradingDate, on: req)
        let yesterday = try await previousTopic(before: tradingDate, on: req.db)
        guard let candidate = DailyBoardFacts.choose(signals, yesterday: yesterday) else {
            try await skip(tradingDate: tradingDate, topic: nil, on: req)
            return .skipped(reason: "no grounded stock, index, or headline")
        }
        let grounded = DailyBoardFacts.grounded(candidate)
        let draft = try await writer.draft(prompt: DailyBoardFacts.prompt(for: candidate), on: req)
        guard let accepted = DailyBoardValidator.accept(title: draft.title, body: draft.body, grounded: grounded) else {
            req.logger.info("daily_board_post draft_rejected reason=ungrounded date=\(tradingDate)")
            throw DailyBoardPostError.ungrounded
        }
        return try await insert(
            tradingDate: tradingDate,
            candidate: candidate,
            title: accepted.title,
            body: accepted.body,
            on: req
        )
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
        let symbolTag = candidate.symbol.lowercased().filter { $0.isLetter || $0.isNumber }
        var tags = [candidate.topic.rawValue]
        if !symbolTag.isEmpty {
            tags.append(symbolTag)
        }
        tags.append("ai")

        let post = BoardPost(
            boardId: identity.boardID,
            authorId: identity.userID,
            kind: kind,
            title: title,
            url: url,
            domain: domain,
            body: body,
            tags: tags,
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

    private static func gather(tradingDate: String, on req: Request) async throws -> DailyBoardSignals {
        let due = MarketBriefSchedule.Due(tradingDate: tradingDate, slot: .evening)
        let symbols = MarketBriefCatalog.groups(for: .evening).flatMap(\.instruments).map(\.symbol)
        let rawQuotes = await quotes.quotes(symbols: symbols, now: Date(), on: req)
        let indexes = MarketBriefGenerator.currentQuotes(rawQuotes, for: due).map { quote in
            DailyBoardFacts.IndexMove(
                symbol: quote.symbol,
                name: MarketBriefCatalog.instrument(symbol: quote.symbol)?.name ?? quote.symbol,
                price: quote.price,
                changePercent: quote.changePercent
            )
        }

        var funds: [String: DailyBoardFacts.FundQuote] = [:]
        for symbol in Set(DailyBoardFacts.fundForIndex.values) {
            if let fund = await fundQuote(symbol, tradingDate: tradingDate, on: req) {
                funds[symbol] = fund
            }
        }

        let headlines = await loadHeadlines(on: req)
        var stocks: [DailyBoardFacts.StockQuote] = []
        for symbol in DailyBoardFacts.rankedTickers(headlines) {
            if let stock = await stockQuote(symbol, tradingDate: tradingDate, on: req) {
                stocks.append(stock)
            }
        }
        return DailyBoardFacts.signals(stocks: stocks, indexes: indexes, funds: funds, headlines: headlines)
    }

    private static func loadHeadlines(on req: Request) async -> [DailyBoardFacts.Headline] {
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

    private static func stockQuote(_ symbol: String, tradingDate: String, on req: Request) async -> DailyBoardFacts.StockQuote? {
        guard let quote = try? await req.application.marketDataService.quote(symbol: symbol, on: req),
              let change = quote.percentChange, change.isFinite
        else { return nil }
        return DailyBoardFacts.StockQuote(
            symbol: quote.symbol,
            price: quote.currentPrice,
            changePercent: change,
            onTradingDate: DailyBoardSchedule.isOnTradingDate(quote.timestamp, tradingDate: tradingDate)
        )
    }

    private static func fundQuote(_ symbol: String, tradingDate: String, on req: Request) async -> DailyBoardFacts.FundQuote? {
        guard let quote = try? await req.application.marketDataService.quote(symbol: symbol, on: req),
              let change = quote.percentChange, change.isFinite
        else { return nil }
        return DailyBoardFacts.FundQuote(
            symbol: quote.symbol,
            price: quote.currentPrice,
            changePercent: change,
            onTradingDate: DailyBoardSchedule.isOnTradingDate(quote.timestamp, tradingDate: tradingDate)
        )
    }

    private static func previousTopic(before tradingDate: String, on db: any Database) async throws -> DailyBoardTopic? {
        guard let run = try await DailyBoardPostRun.query(on: db)
            .filter(\.$id < tradingDate)
            .sort(\.$id, .descending)
            .first()
        else { return nil }
        return run.topic.flatMap(DailyBoardTopic.init(rawValue:))
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
