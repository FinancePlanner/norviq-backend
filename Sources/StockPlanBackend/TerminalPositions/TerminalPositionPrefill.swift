import Foundation
import Vapor

/// Extension point, not implemented in v1: fill `sharesOwned` from the user's
/// holdings (`stocksRepository`) and `currentSharePrice` from
/// `marketDataService.quote`. Prefill must only ever propose values; the user
/// confirms them, exactly like the AI suggestions.
protocol TerminalPositionPrefill: Sendable {
    func sharesOwned(userId: UUID, ticker: String, on req: Request) async throws -> Double?
    func currentSharePrice(ticker: String, on req: Request) async throws -> Double?
}
