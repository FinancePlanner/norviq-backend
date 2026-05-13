import Foundation
@testable import StockPlanBackend
import Testing
import VaporTesting

@Suite("Sharing Tests", .serialized)
struct SharingTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            setenv("SHARE_PUBLIC_BASE_URL", "https://share.norviqa.test", 1)
            setenv("SHARE_OG_IMAGE_URL", "https://cdn.norviqa.test/og/default.png", 1)
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    @Test("Stock share page returns 200 HTML with og:* and twitter:card metadata")
    func stockShareReturnsOGMetadata() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "share/stock/aapl", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentType)?.contains("text/html") == true)
                let body = res.body.string
                #expect(body.contains("<meta property=\"og:type\" content=\"website\">"))
                #expect(body.contains("<meta property=\"og:title\" content=\"$AAPL on Norviqa\">"))
                #expect(body.contains("<meta property=\"og:url\" content=\"https://share.norviqa.test/share/stock/AAPL\">"))
                #expect(body.contains("<meta property=\"og:image\" content=\"https://cdn.norviqa.test/og/default.png\">"))
                #expect(body.contains("<meta name=\"twitter:card\" content=\"summary_large_image\">"))
                #expect(body.contains("<meta name=\"twitter:title\" content=\"$AAPL on Norviqa\">"))
            })
        }
    }

    @Test("Stock share normalizes symbol case and trims unsafe characters")
    func stockShareSanitizesSymbol() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "share/stock/brk.b%3Cscript%3E", afterResponse: { res async in
                #expect(res.status == .ok)
                let body = res.body.string
                #expect(body.contains("$BRK.B on Norviqa"))
                #expect(!body.contains("<script>"))
            })
        }
    }

    @Test("App share page returns 200 HTML with og:* and twitter:card metadata")
    func appShareReturnsOGMetadata() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "share/app", afterResponse: { res async in
                #expect(res.status == .ok)
                let body = res.body.string
                #expect(body.contains("<meta property=\"og:title\" content=\"Norviqa — your portfolio companion\">"))
                #expect(body.contains("<meta property=\"og:url\" content=\"https://share.norviqa.test/share/app\">"))
                #expect(body.contains("<meta name=\"twitter:card\" content=\"summary_large_image\">"))
                #expect(body.contains("apps.apple.com"))
            })
        }
    }

    @Test("Share routes are public — no Authorization header required")
    func shareRoutesArePublic() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "share/stock/AAPL", afterResponse: { res async in
                #expect(res.status == .ok)
            })
            try await app.testing().test(.GET, "share/app", afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("Renderer escapes user-supplied content to prevent injection")
    func rendererEscapesValues() {
        let context = SharingPageContext(
            ogType: "website",
            title: "Hello \"World\" & <evil>",
            description: "Line with <script>alert(1)</script>",
            url: "https://example.com/?a=1&b=2",
            imageURL: "https://example.com/og.png",
            twitterCard: "summary",
            redirect: "https://example.com/?x=<y>",
            extraHead: nil
        )
        let html = SharingHTMLRenderer.render(context)
        #expect(!html.contains("<script>alert(1)</script>"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(html.contains("Hello &quot;World&quot; &amp; &lt;evil&gt;"))
        #expect(html.contains("?a=1&amp;b=2"))
    }
}
