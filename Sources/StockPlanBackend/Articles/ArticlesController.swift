import Fluent
import FluentSQL
import StockPlanShared
import Vapor

/// 404s every article route while ARTICLES_ENABLED is off, before auth runs,
/// so the feature looks like it doesn't exist.
struct ArticlesFlagMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard envBool("ARTICLES_ENABLED", default: false) else { throw Abort(.notFound) }
        return try await next.respond(to: request)
    }
}

struct ArticlesController: RouteCollection {
    static let pageSize = 20
    static let maxPageSize = 100

    func boot(routes: any RoutesBuilder) throws {
        let articles = routes.grouped("articles").grouped(ArticlesFlagMiddleware())

        // Reads: first-party sessions, plus the web's public token (market:read)
        // for logged-out visitors.
        let read = articles.grouped(
            ScopedBearerAuthenticator(), SessionToken.guardMiddleware(), ScopeRequirementMiddleware(.marketRead)
        )
        read.get(use: list)
        read.get(":ref", use: get)

        // Writes: the same gate as Boards (bans, mutes, username, guidelines).
        let write = articles.grouped(
            ScopedBearerAuthenticator(), SessionToken.guardMiddleware(), FirstPartyOnlyMiddleware(), CommunityAccessMiddleware()
        )
        // The daily cap is enforced in the handler against the database; this
        // only stops a burst.
        write.grouped(RateLimitMiddleware(limit: 10, interval: 3600, keyPrefix: "ratelimit:article-create"))
            .post(use: create)
        write.grouped(RateLimitMiddleware(limit: 10, interval: 3600, keyPrefix: "ratelimit:article-edit"))
            .patch(":ref", use: update)
        write.delete(":ref", use: delete)
    }

    // MARK: - Reads

    @Sendable
    func list(req: Request) async throws -> ArticleListResponse {
        let limit = min(max(req.query[Int.self, at: "limit"] ?? Self.pageSize, 1), Self.maxPageSize)
        let query = Article.query(on: req.db).filter(\.$status == ArticleStatus.published.rawValue)

        if let rawTicker = req.query[String.self, at: "ticker"], !rawTicker.isEmpty {
            let ticker = try ArticleValidation.tickers([rawTicker])[0]
            query.filter(.sql(SQLBinaryExpression(left: SQLColumn("tickers"), op: SQLRaw("@>"), right: SQLBind([ticker]))))
        }
        if let username = req.query[String.self, at: "author"], !username.isEmpty {
            guard let author = try await User.query(on: req.db).filter(\.$username == username).first(),
                  let authorId = author.id
            else {
                return ArticleListResponse(items: [], nextCursor: nil)
            }
            query.filter(\.$authorId == authorId)
        }
        if let cursor = req.query[String.self, at: "cursor"], let (date, id) = Self.decodeCursor(cursor) {
            query.group(.or) { or in
                or.filter(\.$publishedAt < date)
                or.group(.and) { and in
                    and.filter(\.$publishedAt == date)
                    and.filter(\.$id < id)
                }
            }
        }

        let rows = try await query.sort(\.$publishedAt, .descending).sort(\.$id, .descending).limit(limit + 1).all()
        let page = Array(rows.prefix(limit))
        let next = rows.count > limit ? page.last.flatMap(Self.encodeCursor) : nil
        return try await ArticleListResponse(items: ArticlePresenter.summaries(page, on: req.db), nextCursor: next)
    }

    @Sendable
    func get(req: Request) async throws -> ArticleDetail {
        let viewer = ArticleService.viewerId(req)
        let article = try await ArticleService.requireVisible(ref: req.parameters.get("ref") ?? "", viewer: viewer, on: req.db)
        return try await ArticlePresenter.detail(article, viewerId: viewer, on: req.db)
    }

    // MARK: - Writes

    @Sendable
    func create(req: Request) async throws -> ArticleDetail {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let input = try req.content.decode(ArticleWriteRequest.self)
        let fields = try await ArticleService.validate(input, authorId: viewer.userId, on: req)

        if !viewer.isAdmin {
            let since = Date().addingTimeInterval(-86400)
            let recent = try await Article.query(on: req.db)
                .filter(\.$authorId == viewer.userId)
                .filter(\.$publishedAt > since)
                .count()
            guard recent < ArticleValidation.maxPerDay else {
                throw CodedAbort(status: .tooManyRequests, code: "article_daily_limit", reason: "You can publish 3 articles a day.")
            }
        }

        let source = input.source.flatMap { $0 == .unknown ? nil : $0 } ?? .web
        let article = Article(
            authorId: viewer.userId, code: "", slug: fields.slug, title: fields.title, bodyMarkdown: fields.body,
            bulletPoints: fields.bulletPoints, tickers: fields.tickers, disclosure: fields.disclosure,
            coverImageId: fields.coverImageId, source: source.rawValue, wordCount: fields.wordCount
        )
        try await ArticleService.insert(article, on: req.db)
        req.logger.notice("articles.published code=\(article.code) source=\(source.rawValue)")
        return try await ArticlePresenter.detail(article, viewerId: viewer.userId, on: req.db)
    }

    @Sendable
    func update(req: Request) async throws -> ArticleDetail {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let article = try await ArticleService.requireVisible(ref: req.parameters.get("ref") ?? "", viewer: viewer.userId, on: req.db)
        guard article.authorId == viewer.userId else {
            throw Abort(.forbidden, reason: "You can only edit your own articles.")
        }
        let fields = try await ArticleService.validate(req.content.decode(ArticleWriteRequest.self), authorId: viewer.userId, on: req)
        article.title = fields.title
        article.slug = fields.slug
        article.bodyMarkdown = fields.body
        article.bulletPoints = fields.bulletPoints
        article.tickers = fields.tickers
        article.disclosure = fields.disclosure
        article.coverImageId = fields.coverImageId
        article.wordCount = fields.wordCount
        article.editedAt = Date()
        try await article.save(on: req.db)
        return try await ArticlePresenter.detail(article, viewerId: viewer.userId, on: req.db)
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        let article = try await ArticleService.requireVisible(ref: req.parameters.get("ref") ?? "", viewer: viewer.userId, on: req.db)
        guard article.authorId == viewer.userId || viewer.isAdmin else {
            throw Abort(.forbidden, reason: "You can only delete your own articles.")
        }
        article.status = ArticleStatus.deleted.rawValue
        try await article.save(on: req.db)
        return .noContent
    }

    // MARK: - Cursor

    /// `<epoch milliseconds>_<uuid>`: stable across equal timestamps.
    static func encodeCursor(_ article: Article) -> String? {
        guard let id = article.id else { return nil }
        return "\(Int64((article.publishedAt.timeIntervalSince1970 * 1000).rounded()))_\(id.uuidString)"
    }

    static func decodeCursor(_ raw: String) -> (Date, UUID)? {
        let parts = raw.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, let millis = Int64(parts[0]), let id = UUID(uuidString: String(parts[1])) else { return nil }
        return (Date(timeIntervalSince1970: Double(millis) / 1000), id)
    }
}
