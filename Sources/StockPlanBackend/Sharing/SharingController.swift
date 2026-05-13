import Foundation
import Vapor

struct SharingController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let share = routes.grouped("share")
        share.get("stock", ":symbol", use: stock)
        share.get("app", use: appLanding)
    }

    @Sendable
    func stock(req: Request) async throws -> Response {
        let rawSymbol = try req.parameters.require("symbol")
        let symbol = sanitizeSymbol(rawSymbol)
        guard !symbol.isEmpty else {
            throw Abort(.badRequest, reason: "Symbol is required.")
        }

        let context = SharingPageContext(
            ogType: "website",
            title: "$\(symbol) on Norviqa",
            description: "Track \(symbol) — fundamentals, valuation, and your thesis on Norviqa.",
            url: shareURL(for: req, path: "/share/stock/\(symbol)"),
            imageURL: ogImageURL(for: req),
            twitterCard: "summary_large_image",
            redirect: appStoreURL,
            extraHead: "<meta name=\"al:ios:app_store_id\" content=\"6745227236\">\n<meta name=\"al:ios:app_name\" content=\"Norviqa\">"
        )
        return try render(context)
    }

    @Sendable
    func appLanding(req: Request) async throws -> Response {
        let context = SharingPageContext(
            ogType: "website",
            title: "Norviqa — your portfolio companion",
            description: "Plan, track, and understand your investments. Available on iOS.",
            url: shareURL(for: req, path: "/share/app"),
            imageURL: ogImageURL(for: req),
            twitterCard: "summary_large_image",
            redirect: appStoreURL,
            extraHead: nil
        )
        return try render(context)
    }

    // MARK: - Helpers

    private static let appStoreFallback = "https://apps.apple.com/us/app/norviqa/id6745227236"

    private var appStoreURL: String {
        Environment.get("SHARE_APP_STORE_URL") ?? Self.appStoreFallback
    }

    private func shareURL(for req: Request, path: String) -> String {
        if let configured = Environment.get("SHARE_PUBLIC_BASE_URL"), !configured.isEmpty {
            return trimTrailingSlash(configured) + path
        }
        let scheme = req.headers.first(name: "X-Forwarded-Proto") ?? "https"
        let host = req.headers.first(name: .host) ?? "localhost"
        return "\(scheme)://\(host)\(path)"
    }

    private func ogImageURL(for req: Request) -> String {
        if let configured = Environment.get("SHARE_OG_IMAGE_URL"), !configured.isEmpty {
            return configured
        }
        return shareURL(for: req, path: "/share/static/og-default.png")
    }

    private func trimTrailingSlash(_ value: String) -> String {
        value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    private func sanitizeSymbol(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        let prefix = raw.unicodeScalars.prefix { allowed.contains($0) }
        return String(String.UnicodeScalarView(prefix)).uppercased()
    }

    private func render(_ context: SharingPageContext) throws -> Response {
        let html = SharingHTMLRenderer.render(context)
        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
        response.headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=300")
        response.body = .init(string: html)
        return response
    }
}

struct SharingPageContext {
    let ogType: String
    let title: String
    let description: String
    let url: String
    let imageURL: String
    let twitterCard: String
    let redirect: String
    let extraHead: String?
}

enum SharingHTMLRenderer {
    static func render(_ context: SharingPageContext) -> String {
        let escapedTitle = escape(context.title)
        let escapedDescription = escape(context.description)
        let escapedURL = escape(context.url)
        let escapedImage = escape(context.imageURL)
        let escapedRedirect = escape(context.redirect)
        let extraHead = context.extraHead.map { "\n    \($0)" } ?? ""

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(escapedTitle)</title>
            <meta name="description" content="\(escapedDescription)">
            <meta property="og:type" content="\(escape(context.ogType))">
            <meta property="og:title" content="\(escapedTitle)">
            <meta property="og:description" content="\(escapedDescription)">
            <meta property="og:url" content="\(escapedURL)">
            <meta property="og:image" content="\(escapedImage)">
            <meta property="og:site_name" content="Norviqa">
            <meta name="twitter:card" content="\(escape(context.twitterCard))">
            <meta name="twitter:title" content="\(escapedTitle)">
            <meta name="twitter:description" content="\(escapedDescription)">
            <meta name="twitter:image" content="\(escapedImage)">\(extraHead)
            <meta http-equiv="refresh" content="0; url=\(escapedRedirect)">
        </head>
        <body>
            <p>Opening Norviqa… <a href="\(escapedRedirect)">Continue to the app</a>.</p>
        </body>
        </html>
        """
    }

    private static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }
}
