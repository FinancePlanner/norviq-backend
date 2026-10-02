import Fluent
import Foundation
import Vapor

/// Resolves the dedicated account that holds a pilot follow's simulated cash.
/// It never adopts another account: the user's manual accounts carry real cash.
enum PilotAccountResolver {
    static let broker = "pilot"

    static func findOrCreate(
        userId: UUID,
        portfolioId: UUID,
        currency: String = "USD",
        on db: any Database
    ) async throws -> Account {
        if let existing = try await Account.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$portfolioId == portfolioId)
            .filter(\.$broker == broker)
            .first()
        {
            return existing
        }
        let account = Account(
            userId: userId,
            externalId: "pilot-\(portfolioId.uuidString.lowercased())",
            broker: broker,
            displayName: "Simulated Cash",
            baseCurrency: currency,
            portfolioId: portfolioId
        )
        try await account.save(on: db)
        return account
    }
}
