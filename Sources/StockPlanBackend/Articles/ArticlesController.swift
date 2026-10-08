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
        read.get("images", ":imageId", use: image)
        read.grouped(ArticleViewRateLimitMiddleware()).post(":ref", "view", use: view)

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
        let votes = write.grouped(RateLimitMiddleware(limit: 60, interval: 60, keyPrefix: "ratelimit:article-vote"))
        votes.post(":ref", "vote", use: vote)
        votes.delete(":ref", "vote", use: unvote)
        write.grouped(RateLimitMiddleware(limit: 20, interval: 3600, keyPrefix: "ratelimit:article-report"))
            .post(":ref", "report", use: report)
        write.grouped(RateLimitMiddleware(limit: 20, interval: 3600, keyPrefix: "ratelimit:article-image"))
            .on(.POST, "images", body: .collect(maxSize: "3mb"), use: uploadImage)

        routes.grouped("admin", "articles")
            .grouped(ArticlesFlagMiddleware(), ScopedBearerAuthenticator(), SessionToken.guardMiddleware(),
                     FirstPartyOnlyMiddleware(), CommunityAccessMiddleware())
            .put(":ref", "visibility", use: setVisibility)
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

        // Before validation, which spends market-data quota on ticker lookups.
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
        let fields = try await ArticleService.validate(input, authorId: viewer.userId, on: req)

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

    // MARK: - Engagement

    static let viewerHeader = "X-Norviq-Viewer"

    /// Counts at most one view per viewer per UTC day. A first-party session is
    /// keyed by user; the web's listed credential forwards a hashed visitor key.
    /// Any other caller (another PAT, OAuth) counts nothing.
    @Sendable
    func view(req: Request) async throws -> HTTPStatus {
        let article = try await ArticleService.requireVisible(ref: req.parameters.get("ref") ?? "", viewer: nil, on: req.db)
        let key: String
        if let viewer = ArticleService.viewerId(req) {
            key = "u:\(viewer.uuidString)"
        } else if ArticleViewerCredentials.isListed(req),
                  let header = req.headers.first(name: Self.viewerHeader),
                  (16 ... 64).contains(header.count), header.allSatisfy(\.isHexDigit)
        {
            key = "v:\(header.lowercased())"
        } else {
            return .noContent
        }
        let articleId = try article.requireID()
        let day = Self.utcDay(Date())
        let sql = try ArticleService.sql(req.db)
        let inserted = try await sql.raw("""
        INSERT INTO article_views (id, article_id, viewer_key, day)
        VALUES (\(bind: UUID()), \(bind: articleId), \(bind: key), \(bind: day))
        ON CONFLICT (article_id, viewer_key, day) DO NOTHING
        RETURNING id
        """).all()
        if !inserted.isEmpty {
            try await sql.raw("UPDATE articles SET view_count = view_count + 1 WHERE id = \(bind: articleId)").run()
        }
        return .noContent
    }

    @Sendable
    func vote(req: Request) async throws -> ArticleVoteResponse {
        try await setVote(true, req: req)
    }

    @Sendable
    func unvote(req: Request) async throws -> ArticleVoteResponse {
        try await setVote(false, req: req)
    }

    /// The vote row and the counter move in one transaction, so the counter is
    /// always the row count.
    private func setVote(_ on: Bool, req: Request) async throws -> ArticleVoteResponse {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let article = try await ArticleService.requireVisible(ref: req.parameters.get("ref") ?? "", viewer: nil, on: req.db)
        let articleId = try article.requireID()
        return try await req.db.transaction { tx in
            let sql = try ArticleService.sql(tx)
            let changed: Bool = if on {
                try await !sql.raw("""
                INSERT INTO article_votes (id, article_id, user_id, created_at)
                VALUES (\(bind: UUID()), \(bind: articleId), \(bind: viewer.userId), \(bind: Date()))
                ON CONFLICT (article_id, user_id) DO NOTHING
                RETURNING id
                """).all().isEmpty
            } else {
                try await !sql.raw("""
                DELETE FROM article_votes WHERE article_id = \(bind: articleId) AND user_id = \(bind: viewer.userId)
                RETURNING id
                """).all().isEmpty
            }
            let delta = changed ? (on ? 1 : -1) : 0
            let row = try await sql.raw("""
            UPDATE articles SET upvote_count = GREATEST(upvote_count + \(bind: delta), 0)
            WHERE id = \(bind: articleId) RETURNING upvote_count
            """).first()
            let count = try row?.decode(column: "upvote_count", as: Int.self) ?? article.upvoteCount
            return ArticleVoteResponse(upvoteCount: count, voted: on)
        }
    }

    /// Reporting skips requireCanContribute on purpose: a muted person must
    /// still be able to flag a scam.
    @Sendable
    func report(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        let article = try await ArticleService.requireVisible(ref: req.parameters.get("ref") ?? "", viewer: nil, on: req.db)
        let body = try req.content.decode(ArticleReportRequest.self)
        let note = body.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (note?.count ?? 0) <= 1000 else {
            throw Abort(.badRequest, reason: "Keep the details under 1,000 characters.")
        }
        try await SocialReport(
            reporterId: viewer.userId,
            targetType: "article",
            targetId: article.requireID().uuidString,
            reason: body.reason.rawValue,
            note: (note?.isEmpty ?? true) ? nil : note
        ).save(on: req.db)
        req.logger.notice("articles.report filed code=\(article.code) reason=\(body.reason.rawValue)")

        let reason = body.reason.rawValue
        let excerpt = "\(article.code) · \(article.title)"
        Task {
            do {
                try await req.discord.send("🚩 Article report (\(reason)):\n```\(excerpt.prefix(300))```", on: req)
            } catch {
                req.logger.warning("articles.report discord ping failed: \(String(describing: error))")
            }
        }
        return .noContent
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    /// `yyyy-MM-dd` in UTC.
    static func utcDay(_ date: Date) -> String {
        let day = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
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

    // MARK: - Images

    private struct ImageUpload: Content {
        var file: File
    }

    @Sendable
    func uploadImage(req: Request) async throws -> ArticleImageUploadResponse {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let upload = try req.content.decode(ImageUpload.self)
        let bytes = Array(upload.file.data.readableBytesView)
        let sniffed = try ArticleImageSniffer.sniff(bytes)
        let image = ArticleImage(ownerId: viewer.userId, image: sniffed, bytes: Data(bytes))
        try await image.create(on: req.db)
        return try ArticleImageUploadResponse(id: image.requireID())
    }

    @Sendable
    func image(req: Request) async throws -> Response {
        guard let id = req.parameters.get("imageId", as: UUID.self),
              let image = try await ArticleImage.find(id, on: req.db)
        else {
            throw Abort(.notFound)
        }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: image.contentType)
        // Image ids are never reused and the bytes never change.
        headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=31536000, immutable")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        return Response(status: .ok, headers: headers, body: .init(data: image.bytes))
    }

    // MARK: - Moderation

    @Sendable
    func setVisibility(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        guard viewer.isAdmin else { throw Abort(.forbidden, reason: "Admin access required.") }
        guard let article = try await ArticleService.find(ref: req.parameters.get("ref") ?? "", on: req.db),
              article.status != ArticleStatus.deleted.rawValue
        else {
            throw Abort(.notFound, reason: "Article not found")
        }
        let body = try req.content.decode(ArticleVisibilityRequest.self)
        article.status = body.hidden ? ArticleStatus.hidden.rawValue : ArticleStatus.published.rawValue
        try await article.save(on: req.db)
        req.logger.notice("articles.visibility code=\(article.code) hidden=\(body.hidden) by=\(viewer.userId)")
        return .noContent
    }
}
