import Vapor

/// Fans out to several providers and merges their results. A child that fails
/// is logged and skipped, never propagated: one dead vendor must not blank the
/// whole feed. Results are deduped by URL, first provider wins.
struct CompositeNewsProvider: NewsProvider {
    let providers: [any NewsProvider]

    var name: String {
        "composite(\(providers.map(\.name).joined(separator: ",")))"
    }

    func fetch(symbols: [String], on req: Request) async throws -> [ProviderNewsItem] {
        try await merge(on: req) { try await $0.fetch(symbols: symbols, on: req) }
    }

    func fetchGeneral(on req: Request) async throws -> [ProviderNewsItem] {
        try await merge(on: req) { try await $0.fetchGeneral(on: req) }
    }

    private func merge(on req: Request, _ call: (any NewsProvider) async throws -> [ProviderNewsItem]) async throws -> [ProviderNewsItem] {
        var seen = Set<String>()
        var out: [ProviderNewsItem] = []
        var failures = 0
        for provider in providers {
            do {
                for item in try await call(provider) {
                    if let url = item.url, !url.isEmpty {
                        guard seen.insert(url.lowercased()).inserted else { continue }
                    }
                    out.append(item)
                }
            } catch {
                failures += 1
                req.logger.warning("news.composite provider=\(provider.name) failed error=\(error)")
            }
        }
        if failures == providers.count, !providers.isEmpty {
            throw Abort(.badGateway, reason: "All news providers failed.")
        }
        return out
    }
}
