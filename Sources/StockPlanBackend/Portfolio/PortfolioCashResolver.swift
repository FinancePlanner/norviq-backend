import Fluent
import Foundation

/// Resolves a user's cash position the same way the portfolio endpoints do.
///
/// Extracted from `PortfolioController` so the planning endpoints can pre-fill a starting
/// amount without restating the rules. The subtleties are worth stating once: cash is held
/// per account *and* per currency, only the most recent row for each pair counts, negative
/// balances are floored at zero, and manually entered portfolio cash is only included when a
/// specific portfolio is named.
enum PortfolioCashResolver {
    static func totalCashBalance(
        userId: UUID,
        portfolioId: UUID?,
        on db: any Database
    ) async throws -> Double {
        let accountQuery = Account.query(on: db).filter(\.$userId == userId)
        if let portfolioId {
            accountQuery.filter(\.$portfolioId == portfolioId)
        }
        let accounts = try await accountQuery.all()
        let accountIds = accounts.compactMap(\.id)
        let balances = accountIds.isEmpty
            ? []
            : try await CashBalance.query(on: db).filter(\.$accountId ~~ accountIds).all()
        var latestByAccountCurrency: [String: CashBalance] = [:]
        for balance in balances {
            let key = "\(balance.accountId.uuidString.lowercased())::\(balance.currency.uppercased())"
            if let existing = latestByAccountCurrency[key] {
                let existingDate = existing.asOf
                if balance.asOf > existingDate {
                    latestByAccountCurrency[key] = balance
                }
            } else {
                latestByAccountCurrency[key] = balance
            }
        }

        let accountCash = latestByAccountCurrency.values.reduce(0) { $0 + max(0, $1.balance) }
        guard let portfolioId else { return accountCash }
        let manualCash = try await PortfolioCashPositionRecord.query(on: db)
            .filter(\.$portfolioId == portfolioId)
            .all()
            .reduce(0) { $0 + max(0, $1.balance) }
        return accountCash + manualCash
    }
}
