import Fluent
import FluentSQL
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Article images and moderation", .serialized)
struct ArticleImagesAndModerationTests {
    typealias Kit = ArticleTestKit

    private func upload(_ app: Application, _ bytes: [UInt8], as auth: AuthResponse) async throws -> Kit.Reply {
        let boundary = "norviq-test-boundary"
        var body = ByteBuffer()
        body.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"c.png\"\r\nContent-Type: image/png\r\n\r\n")
        body.writeBytes(bytes)
        body.writeString("\r\n--\(boundary)--\r\n")
        var reply: Kit.Reply?
        try await app.testing().test(.POST, "v1/articles/images", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: auth.token)
            req.headers.contentType = HTTPMediaType(type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
            req.body = body
        }, afterResponse: { res async throws in
            reply = Kit.Reply(status: res.status, body: Data(res.body.readableBytesView))
        })
        return try #require(reply)
    }

    @Test("upload a PNG, attach it as the cover, and fetch it back with day-long public caching")
    func coverRoundTrip() async throws {
        try await Kit.withApp { app in
            let ana = try await Kit.member(app, "img_ana")
            let png = ArticleImageSnifferTests.png(width: 1200, height: 630)
            let uploaded = try await upload(app, png, as: ana)
            #expect(uploaded.status == .ok)
            let imageId = try uploaded.decode(ArticleImageUploadResponse.self).id

            let detail = try await Kit.publish(app, as: ana, Kit.input(cover: imageId))
            #expect(detail.article.coverImageId == imageId)

            try await app.testing().test(.GET, "v1/articles/images/\(imageId)", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: ana.token)
            }) { res in
                #expect(res.status == .ok)
                #expect(res.headers.contentType?.description == "image/png")
                #expect(res.headers.first(name: .cacheControl) == "public, max-age=86400")
                #expect(Array(res.body.readableBytesView) == png)
            }
        }
    }

    @Test("an SVG upload is 415; someone else's image can't be used as a cover")
    func rejects() async throws {
        try await Kit.withApp { app in
            let ana = try await Kit.member(app, "rej_ana")
            let bo = try await Kit.member(app, "rej_bo")
            #expect(try await upload(app, Array("<svg onload=alert(1)>".utf8), as: ana).status == .unsupportedMediaType)
            let imageId = try await upload(app, ArticleImageSnifferTests.png(width: 10, height: 10), as: ana)
                .decode(ArticleImageUploadResponse.self).id
            #expect(try await Kit.send(app, .POST, "v1/articles", as: bo, body: Kit.input(cover: imageId)).status == .badRequest)
        }
    }

    @Test("ten uploads a day, then 429 article_image_daily_limit; admins are exempt")
    func dailyUploadCap() async throws {
        try await Kit.withApp { app in
            let admin = try await Kit.member(app, "cap_admin", email: Kit.adminEmail)
            let ana = try await Kit.member(app, "cap_ana")
            let png = ArticleImageSnifferTests.png(width: 10, height: 10)
            for _ in 1 ... 10 {
                #expect(try await upload(app, png, as: ana).status == .ok)
                #expect(try await upload(app, png, as: admin).status == .ok)
            }
            let eleventh = try await upload(app, png, as: ana)
            #expect(eleventh.status == .tooManyRequests && eleventh.code == "article_image_daily_limit")
            #expect(try await upload(app, png, as: admin).status == .ok)

            // The window is rolling: uploads older than a day stop counting.
            try await backdate(app, owner: ana.userId)
            #expect(try await upload(app, png, as: ana).status == .ok)
        }
    }

    @Test("an upload clears the owner's day-old images that no article uses, and nothing else")
    func uploadCleansUpOrphans() async throws {
        try await Kit.withApp { app in
            let ana = try await Kit.member(app, "orph_ana")
            let bo = try await Kit.member(app, "orph_bo")
            let png = ArticleImageSnifferTests.png(width: 10, height: 10)
            let orphan = try await upload(app, png, as: ana).decode(ArticleImageUploadResponse.self).id
            let cover = try await upload(app, png, as: ana).decode(ArticleImageUploadResponse.self).id
            let deletedCover = try await upload(app, png, as: ana).decode(ArticleImageUploadResponse.self).id
            let fresh = try await upload(app, png, as: ana).decode(ArticleImageUploadResponse.self).id
            let bosOrphan = try await upload(app, png, as: bo).decode(ArticleImageUploadResponse.self).id
            _ = try await Kit.publish(app, as: ana, Kit.input(cover: cover))
            let deleted = try await Kit.publish(app, as: ana, Kit.input(title: "Second article about NEXT", cover: deletedCover))
            #expect(try await Kit.send(app, .DELETE, "v1/articles/\(deleted.article.code)", as: ana).status == .noContent)
            try await backdate(app, owner: ana.userId, except: fresh)
            try await backdate(app, owner: bo.userId)

            #expect(try await upload(app, png, as: ana).status == .ok)

            #expect(try await ArticleImage.find(orphan, on: app.db) == nil)
            // Any article still pointing at it keeps it, deleted ones included.
            #expect(try await ArticleImage.find(cover, on: app.db) != nil)
            #expect(try await ArticleImage.find(deletedCover, on: app.db) != nil)
            #expect(try await ArticleImage.find(fresh, on: app.db) != nil)
            #expect(try await ArticleImage.find(bosOrphan, on: app.db) != nil)
        }
    }

    @Test("a cover is served only while a published article uses it, or to its owner or an admin")
    func coverServing() async throws {
        try await Kit.withApp { app in
            let admin = try await Kit.member(app, "srv_admin", email: Kit.adminEmail)
            let ana = try await Kit.member(app, "srv_ana")
            let bo = try await Kit.member(app, "srv_bo")
            let web = try await Kit.credential(app, owner: admin)
            let png = ArticleImageSnifferTests.png(width: 10, height: 10)
            let used = try await upload(app, png, as: ana).decode(ArticleImageUploadResponse.self).id
            let loose = try await upload(app, png, as: ana).decode(ArticleImageUploadResponse.self).id
            let code = try await Kit.publish(app, as: ana, Kit.input(cover: used)).article.code
            func get(_ id: UUID, token: String) async throws -> Kit.Reply {
                try await Kit.send(app, .GET, "v1/articles/images/\(id)", token: token)
            }

            let published = try await get(used, token: web.token)
            #expect(published.status == .ok)
            #expect(published.headers.first(name: .cacheControl) == "public, max-age=86400")
            #expect(try await get(used, token: bo.token).status == .ok)

            #expect(try await get(loose, token: bo.token).status == .notFound)
            #expect(try await get(loose, token: web.token).status == .notFound)
            let ownerOnly = try await get(loose, token: ana.token)
            #expect(ownerOnly.status == .ok)
            // Never into a shared cache: it would outlive the owner-only check.
            #expect(ownerOnly.headers.first(name: .cacheControl) == "private, no-store")
            #expect(try await get(loose, token: admin.token).status == .ok)

            #expect(try await Kit.send(app, .PUT, "v1/admin/articles/\(code)/visibility", as: admin, body: ArticleVisibilityRequest(hidden: true)).status == .noContent)
            #expect(try await get(used, token: web.token).status == .notFound)
            #expect(try await get(used, token: bo.token).status == .notFound)
            #expect(try await get(used, token: ana.token).status == .ok)
        }
    }

    /// Moves an owner's uploads 25 hours into the past.
    private func backdate(_ app: Application, owner: UUID, except kept: UUID? = nil) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        try await sql.raw("""
        UPDATE article_images SET created_at = created_at - interval '25 hours'
        WHERE owner_id = \(bind: owner) AND id IS DISTINCT FROM \(bind: kept)
        """).run()
    }

    @Test("hidden articles are visible to their author and admins only, and leave the feed")
    func hiddenIsAuthorAndAdminOnly() async throws {
        try await Kit.withApp { app in
            let admin = try await Kit.member(app, "mod_admin", email: Kit.adminEmail)
            let ana = try await Kit.member(app, "mod_ana")
            let bo = try await Kit.member(app, "mod_bo")
            let code = try await Kit.publish(app, as: ana).article.code

            #expect(try await Kit.send(app, .PUT, "v1/admin/articles/\(code)/visibility", as: bo, body: ArticleVisibilityRequest(hidden: true)).status == .forbidden)
            #expect(try await Kit.send(app, .PUT, "v1/admin/articles/\(code)/visibility", as: admin, body: ArticleVisibilityRequest(hidden: true)).status == .noContent)

            #expect(try await Kit.send(app, .GET, "v1/articles/\(code)", as: bo).status == .notFound)
            #expect(try await Kit.send(app, .GET, "v1/articles/\(code)", as: ana).status == .ok)
            #expect(try await Kit.send(app, .GET, "v1/articles/\(code)", as: admin).status == .ok)
            #expect(try await Kit.send(app, .GET, "v1/articles", as: bo).decode(ArticleListResponse.self).items.isEmpty)

            #expect(try await Kit.send(app, .PUT, "v1/admin/articles/\(code)/visibility", as: admin, body: ArticleVisibilityRequest(hidden: false)).status == .noContent)
            #expect(try await Kit.send(app, .GET, "v1/articles/\(code)", as: bo).status == .ok)
        }
    }
}
