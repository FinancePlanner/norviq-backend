import Fluent
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

    @Test("upload a PNG, attach it as the cover, and fetch it back with immutable caching")
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
                #expect(res.headers.first(name: .cacheControl) == "public, max-age=31536000, immutable")
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
