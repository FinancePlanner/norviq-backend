import Foundation
import Vapor

/// Input rules for boards, posts and comments. Pure, so they test without a
/// database.
enum CommunityValidation {
    static let maxBoardsPerDay = 3
    static let maxTitleLength = 200
    static let maxPostBodyLength = 10000
    static let maxCommentLength = 5000
    static let maxTags = 5
    static let maxTagLength = 24
    static let maxCommentDepth = 8

    /// Paths the web app or an admin screen owns, or that read as official.
    static let reservedSlugs: Set<String> = [
        "admin", "api", "new", "create", "edit", "settings", "submit", "search",
        "norviq", "official", "support", "help", "mod", "mods", "moderator", "staff",
        // Static web routes under /boards/.
        "guidelines", "block", "report", "activity",
    ]

    static func slug(_ raw: String) throws -> String {
        let slug = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = slug.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        guard (3 ... 32).contains(slug.count), allowed, !slug.hasPrefix("-"), !slug.hasSuffix("-") else {
            throw Abort(.badRequest, reason: "Board address must be 3–32 lowercase letters, numbers or dashes.")
        }
        guard !reservedSlugs.contains(slug) else {
            throw Abort(.badRequest, reason: "That board address is reserved.")
        }
        return slug
    }

    static func boardName(_ raw: String) throws -> String {
        let name = collapse(raw)
        guard (3 ... 60).contains(name.count) else {
            throw Abort(.badRequest, reason: "Board name must be 3–60 characters.")
        }
        return name
    }

    static func boardDescription(_ raw: String) throws -> String {
        let description = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard description.count <= 500 else {
            throw Abort(.badRequest, reason: "Keep the description under 500 characters.")
        }
        return description
    }

    static func title(_ raw: String) throws -> String {
        let title = collapse(raw)
        guard (3 ... maxTitleLength).contains(title.count) else {
            throw Abort(.badRequest, reason: "Title must be 3–\(maxTitleLength) characters.")
        }
        return title
    }

    static func postBody(_ raw: String?) throws -> String? {
        let body = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard body.count <= maxPostBodyLength else {
            throw Abort(.badRequest, reason: "Keep the post under \(maxPostBodyLength) characters.")
        }
        return body.isEmpty ? nil : body
    }

    static func commentBody(_ raw: String) throws -> String {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.count <= maxCommentLength else {
            throw Abort(.badRequest, reason: "Comment must be 1–\(maxCommentLength) characters.")
        }
        return body
    }

    /// Lowercased, deduplicated, order kept. A leading `#` is dropped.
    static func tags(_ raw: [String]) throws -> [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for value in raw {
            var tag = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if tag.hasPrefix("#") {
                tag.removeFirst()
            }
            guard !tag.isEmpty else { continue }
            let allowed = tag.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
            guard allowed, tag.count <= maxTagLength else {
                throw Abort(.badRequest, reason: "Tags are up to \(maxTagLength) letters, numbers or dashes.")
            }
            if seen.insert(tag).inserted {
                tags.append(tag)
            }
        }
        guard tags.count <= maxTags else {
            throw Abort(.badRequest, reason: "Use at most \(maxTags) tags.")
        }
        return tags
    }

    /// Accepts only absolute http(s) URLs with a host. The server never
    /// fetches it; the domain is for display.
    static func link(_ raw: String?) throws -> (url: String, domain: String) {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.count <= 2000,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), host.contains("."), components.user == nil
        else {
            throw Abort(.badRequest, reason: "Link posts need a full http(s) URL.")
        }
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return (trimmed, domain)
    }

    private static func collapse(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
