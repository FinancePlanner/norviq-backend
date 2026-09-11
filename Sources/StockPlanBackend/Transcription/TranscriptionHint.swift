import Fluent
import Foundation
import Vapor

/// Vocabulary passed to the recogniser so it stops mishearing tickers.
enum TranscriptionHint {
    /// Enough to cover a real watchlist, small enough that the prompt stays a
    /// hint rather than a payload.
    static let maxSymbols = 40

    static func build(symbols: [String]) -> String? {
        var seen = Set<String>()
        var kept: [String] = []
        for symbol in symbols {
            let normalised = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !normalised.isEmpty, seen.insert(normalised).inserted else { continue }
            kept.append(normalised)
            if kept.count == maxSymbols {
                break
            }
        }
        guard !kept.isEmpty else { return nil }
        return "Tickers that may be mentioned: \(kept.joined(separator: ", "))."
    }

    /// The user's watchlist symbols. Cheap: one indexed column on one table.
    static func forUser(_ userId: UUID, req: Request) async -> String? {
        do {
            let items = try await WatchlistItem.query(on: req.db)
                .filter(\.$userId == userId)
                .limit(maxSymbols)
                .all()
            return build(symbols: items.map(\.symbol))
        } catch {
            // A missing hint degrades accuracy; it must never fail the turn.
            req.logger.warning("transcription_hint_failed userId=\(userId)")
            return nil
        }
    }
}
