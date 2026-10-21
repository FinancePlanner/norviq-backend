import Foundation
import StockPlanShared
import Vapor

/// Input rules and limits for groups, channels and messages. Pure, so they
/// test without a database.
enum GroupsValidation {
    static let maxGroupsCreatedPerDay = 3
    static let maxGroupsOwned = 10
    static let maxGroupsJoined = 100
    static let maxMembers = 250
    static let maxChannels = 20
    static let maxMessageLength = 2000
    static let maxMessagesPerDay = 600
    static let maxActiveInviteLinks = 25
    static let maxDirectInvitations = 25
    static let maxInviteHours = 24 * 30
    static let maxInviteUses = 1000
    static let defaultChannelName = "general"

    static func groupName(_ raw: String) throws -> String {
        let name = collapse(raw)
        guard (2 ... 50).contains(name.count) else {
            throw Abort(.badRequest, reason: "Group name must be 2–50 characters.")
        }
        try GroupsContentFilter.check(name)
        return name
    }

    static func groupDescription(_ raw: String?) throws -> String {
        let description = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard description.count <= 300 else {
            throw Abort(.badRequest, reason: "Keep the description under 300 characters.")
        }
        try GroupsContentFilter.check(description)
        return description
    }

    /// One emoji, or nil for none.
    static func iconEmoji(_ raw: String?) throws -> String? {
        let icon = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !icon.isEmpty else { return nil }
        guard icon.count == 1, let character = icon.first, isEmoji(character) else {
            throw Abort(.badRequest, reason: "The icon must be a single emoji.")
        }
        return icon
    }

    /// `$aapl` → `AAPL`. Allows class shares and pairs (`BRK.B`, `BTC-USD`).
    /// Empty input is nil, which clears the ticker on update.
    static func ticker(_ raw: String?, topic: GroupTopic) throws -> String? {
        var ticker = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if ticker.hasPrefix("$") {
            ticker.removeFirst()
        }
        guard !ticker.isEmpty else { return nil }
        guard topic.allowsTicker else {
            throw Abort(.badRequest, reason: "Only stock, ETF and crypto groups take a ticker.")
        }
        guard isTicker(ticker) else {
            throw Abort(.badRequest, reason: "That doesn't look like a ticker.")
        }
        return ticker
    }

    static func isTicker(_ ticker: String) -> Bool {
        guard (1 ... 12).contains(ticker.count), let first = ticker.first,
              first.isASCII, first.isLetter || first.isNumber
        else { return false }
        return ticker.allSatisfy { ($0.isASCII && ($0.isUppercase || $0.isNumber)) || $0 == "." || $0 == "-" }
    }

    /// `"Earnings Talk"` → `earnings-talk`.
    static func channelName(_ raw: String) throws -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var name = ""
        for character in lowered {
            if character == " " || character == "_" || character == "-" {
                if !name.isEmpty, name.last != "-" {
                    name.append("-")
                }
            } else {
                name.append(character)
            }
        }
        while name.hasSuffix("-") {
            name.removeLast()
        }
        let allowed = name.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
        guard (1 ... 32).contains(name.count), allowed else {
            throw Abort(.badRequest, reason: "Channel names are 1–32 lowercase letters, numbers or dashes.")
        }
        try GroupsContentFilter.check(name)
        return name
    }

    static func channelTopic(_ raw: String?) throws -> String? {
        let topic = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return nil }
        guard topic.count <= 200 else {
            throw Abort(.badRequest, reason: "Keep the channel topic under 200 characters.")
        }
        try GroupsContentFilter.check(topic)
        return topic
    }

    static func messageBody(_ raw: String) throws -> String {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw Abort(.badRequest, reason: "Write something first.")
        }
        guard body.count <= maxMessageLength else {
            throw Abort(.badRequest, reason: "Messages are limited to \(maxMessageLength) characters.")
        }
        try GroupsContentFilter.check(body)
        return body
    }

    static func clientMessageId(_ raw: String) throws -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 64).contains(id.count) else {
            throw Abort(.badRequest, reason: "clientMessageId must be 1–64 characters.")
        }
        return id
    }

    static func invite(_ request: CreateGroupInviteRequest, now: Date = Date()) throws -> (expiresAt: Date?, maxUses: Int?) {
        if let hours = request.expiresInHours, !(1 ... maxInviteHours).contains(hours) {
            throw Abort(.badRequest, reason: "Invites last between 1 hour and 30 days, or never expire.")
        }
        if let uses = request.maxUses, !(1 ... maxInviteUses).contains(uses) {
            throw Abort(.badRequest, reason: "An invite can be used 1–\(maxInviteUses) times, or without limit.")
        }
        return (request.expiresInHours.map { now.addingTimeInterval(TimeInterval($0) * 3600) }, request.maxUses)
    }

    private static func collapse(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        // Digits and `#` are "emoji" on their own; they only count with a
        // variation selector or keycap, which makes them multi-scalar.
        if scalars.contains(where: \.properties.isEmojiPresentation) {
            return true
        }
        return scalars.count > 1 && scalars.first?.properties.isEmoji == true
    }
}

/// Server-side text filter for everything members write into a group. App
/// Store guideline 1.2 wants objectionable content filtered, not only
/// reportable. Matching is on whole words after normalising case, accents
/// and common digit-for-letter swaps, and each letter of a term may repeat,
/// so `N1GGGG3R` is caught while `Niger` and `Scunthorpe` are not.
/// `GROUPS_BLOCKED_TERMS` (comma-separated) extends the built-in list without
/// a code change.
enum GroupsContentFilter {
    /// Slurs only. Ordinary profanity is allowed; moderators handle the rest.
    static let builtInTerms = [
        "nigger", "nigga", "faggot", "kike", "chink", "gook",
        "wetback", "tranny", "raghead", "towelhead",
    ]

    static func check(_ text: String, extraTerms: [String] = environmentTerms()) throws {
        guard isAllowed(text, extraTerms: extraTerms) else {
            throw CodedAbort(
                status: .unprocessableEntity,
                code: "content_rejected",
                reason: "This wasn't sent because it may break the community guidelines."
            )
        }
    }

    static func isAllowed(_ text: String, extraTerms: [String] = []) -> Bool {
        let haystack = normalize(text)
        guard !haystack.isEmpty else { return true }
        let range = NSRange(haystack.startIndex..., in: haystack)
        for term in builtInTerms + extraTerms {
            guard let pattern = pattern(for: term) else { continue }
            if pattern.firstMatch(in: haystack, range: range) != nil {
                return false
            }
        }
        return true
    }

    static func environmentTerms() -> [String] {
        (Environment.get("GROUPS_BLOCKED_TERMS") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Lowercase ASCII words separated by single spaces, with leetspeak
    /// mapped back to letters.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        let leet: [Character: Character] = [
            "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s",
        ]
        var result = ""
        for raw in folded {
            let character = leet[raw] ?? raw
            if character.isASCII, character.isLetter {
                result.append(character)
            } else if !result.isEmpty, result.last != " " {
                result.append(" ")
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// A multi-word term matches across single spaces; each letter may repeat.
    private static func pattern(for term: String) -> NSRegularExpression? {
        let words = normalize(term).split(separator: " ")
        guard !words.isEmpty else { return nil }
        let body = words.map { word in word.map { "\($0)+" }.joined() }.joined(separator: " ")
        return try? NSRegularExpression(pattern: "(?:^| )\(body)(?: |$)")
    }
}
