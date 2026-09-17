import Vapor

/// Parses `NEWS_PROVIDERS` and assembles the provider chain.
enum NewsProviderSelection {
    static let known: Set<String> = ["finnhub", "jsonfeed"]

    /// Aliases kept so the older documented names still work.
    private static let aliases: [String: String] = [
        "rss": "jsonfeed", "yahoo": "jsonfeed", "yahoo_rss": "jsonfeed",
    ]

    /// Lowercased, trimmed, deduped, aliases resolved, unknown names dropped.
    /// Empty or missing input means `finnhub`.
    static func parse(_ raw: String?) -> [String] {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ["finnhub"]
        }
        var seen = Set<String>()
        return trimmed
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .map { aliases[$0] ?? $0 }
            .filter { known.contains($0) && seen.insert($0).inserted }
    }

    /// Returns nil when nothing is configured, the single provider when one is,
    /// or a composite in the configured order. Providers whose prerequisites
    /// are missing (no key, no base URL) are skipped.
    static func build(names: [String], finnhub: (any NewsProvider)?, jsonfeed: (any NewsProvider)?) -> (any NewsProvider)? {
        let available: [any NewsProvider] = names.compactMap { name in
            switch name {
            case "finnhub": finnhub
            case "jsonfeed": jsonfeed
            default: nil
            }
        }
        switch available.count {
        case 0: return nil
        case 1: return available[0]
        default: return CompositeNewsProvider(providers: available)
        }
    }
}
