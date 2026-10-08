import Fluent
import StockPlanShared
import Vapor

enum ArticlePresenter {
    static func summary(_ article: Article, author: User?) throws -> ArticleSummary {
        try ArticleSummary(
            id: article.requireID(),
            code: article.code,
            slug: article.slug,
            title: article.title,
            bulletPoints: article.bulletPoints,
            tickers: article.tickers,
            author: ArticleAuthor(id: article.authorId, username: author?.username, avatarURL: author?.avatarURLString),
            coverImageId: article.coverImageId,
            upvoteCount: article.upvoteCount,
            viewCount: article.viewCount,
            wordCount: article.wordCount,
            status: ArticleStatus(rawValue: article.status) ?? .unknown,
            source: ArticleSource(rawValue: article.source) ?? .unknown,
            publishedAt: article.publishedAt,
            editedAt: article.editedAt
        )
    }

    /// One users query for the whole page.
    static func summaries(_ articles: [Article], on db: any Database) async throws -> [ArticleSummary] {
        let authorIds = Array(Set(articles.map(\.authorId)))
        let authors = try await User.query(on: db).filter(\.$id ~~ authorIds).all()
        let byId = Dictionary(uniqueKeysWithValues: authors.compactMap { user in user.id.map { ($0, user) } })
        return try articles.map { try summary($0, author: byId[$0.authorId]) }
    }

    static func detail(_ article: Article, viewerId: UUID?, on db: any Database) async throws -> ArticleDetail {
        let author = try await User.find(article.authorId, on: db)
        var upvoted = false
        if let viewerId {
            upvoted = try await ArticleVote.query(on: db)
                .filter(\.$articleId == article.requireID())
                .filter(\.$userId == viewerId)
                .first() != nil
        }
        return try ArticleDetail(
            article: summary(article, author: author),
            bodyMarkdown: article.bodyMarkdown,
            disclosure: article.disclosure,
            viewerUpvoted: upvoted,
            viewerIsAuthor: viewerId == article.authorId
        )
    }
}
