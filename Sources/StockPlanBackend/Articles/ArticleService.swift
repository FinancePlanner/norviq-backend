import Fluent
import FluentSQL
import StockPlanShared
import Vapor

/// Lookups and rules shared by every article handler.
enum ArticleService {
    /// `ref` is the article's uuid or its 8-character code.
    static func find(ref: String, on db: any Database) async throws -> Article? {
        if let id = UUID(uuidString: ref) {
            return try await Article.find(id, on: db)
        }
        let code = ref.lowercased()
        guard code.count == 8 else { return nil }
        return try await Article.query(on: db).filter(\.$code == code).first()
    }

    /// The signed-in person behind a first-party session. A third-party token
    /// (the web's public token, a PAT) is nobody: it reads anonymously.
    static func viewerId(_ req: Request) -> UUID? {
        guard !req.auth.has(ScopeContext.self) else { return nil }
        return req.auth.get(SessionToken.self)?.userId
    }

    static func isAdmin(_ userId: UUID, on db: any Database) async -> Bool {
        await (try? CommunityAccess.viewer(for: userId, on: db).isAdmin) ?? false
    }

    /// Published articles are visible to all. Hidden ones only to their author
    /// and admins. Deleted ones only to admins. Everyone else gets a 404, so a
    /// hidden article is indistinguishable from one that never existed.
    static func requireVisible(ref: String, viewer: UUID?, on db: any Database) async throws -> Article {
        guard let article = try await find(ref: ref, on: db) else {
            throw Abort(.notFound, reason: "Article not found")
        }
        switch article.status {
        case ArticleStatus.published.rawValue:
            return article
        case ArticleStatus.hidden.rawValue:
            if let viewer, viewer == article.authorId {
                return article
            }
            if let viewer, await isAdmin(viewer, on: db) {
                return article
            }
        default:
            if let viewer, await isAdmin(viewer, on: db) {
                return article
            }
        }
        throw Abort(.notFound, reason: "Article not found")
    }

    struct Fields {
        let title: String
        let slug: String
        let body: String
        let bulletPoints: [String]
        let tickers: [String]
        let disclosure: String
        let coverImageId: UUID?
        let wordCount: Int
    }

    static func validate(_ input: ArticleWriteRequest, authorId: UUID, on req: Request) async throws -> Fields {
        let title = try ArticleValidation.title(input.title)
        let body = try ArticleValidation.body(input.bodyMarkdown)
        let bullets = try ArticleValidation.bulletPoints(input.bulletPoints)
        let tickers = try ArticleValidation.tickers(input.tickers)
        let disclosure = try ArticleValidation.disclosure(input.disclosure)
        for ticker in tickers {
            if await req.application.articleTickerVerifier.check(ticker, on: req) == .missing {
                throw Abort(.badRequest, reason: "We couldn't find the ticker \(ticker).")
            }
        }
        if let coverId = input.coverImageId {
            guard let image = try await ArticleImage.find(coverId, on: req.db), image.ownerId == authorId else {
                throw Abort(.badRequest, reason: "Upload the cover image again.")
            }
        }
        return Fields(
            title: title, slug: ArticleValidation.slug(from: title), body: body, bulletPoints: bullets,
            tickers: tickers, disclosure: disclosure, coverImageId: input.coverImageId,
            wordCount: ArticleValidation.wordCount(markdown: body)
        )
    }

    /// Inserts with a fresh code, retrying on the rare collision.
    static func insert(_ article: Article, on db: any Database) async throws {
        for attempt in 1 ... 5 {
            article.code = ArticleValidation.makeCode()
            do {
                try await article.create(on: db)
                return
            } catch let error as any DatabaseError where error.isConstraintFailure && attempt < 5 {
                article.id = nil
                continue
            }
        }
    }

    static func sql(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Articles need a SQL database")
        }
        return sql
    }
}
