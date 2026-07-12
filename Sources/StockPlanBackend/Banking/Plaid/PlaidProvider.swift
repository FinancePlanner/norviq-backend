import Crypto
import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Plaid driver. Strictly read-only: the link token requests only the
/// `transactions` product, and no endpoint here can move money.
struct PlaidProvider: BankProvider {
    let kind: BankProviderKind = .plaid
    let client: PlaidClient

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    func createLinkSession(userId: UUID, on req: Request) async throws -> BankLinkSessionResponse {
        let token = try await client.createLinkToken(userId: userId, on: req)
        let expiration = token.expiration.flatMap { ISO8601DateFormatter().date(from: $0) }
        return BankLinkSessionResponse(provider: .plaid, linkToken: token.linkToken, hostedURL: nil, expiration: expiration)
    }

    func exchange(_ request: BankExchangeRequest, userId: UUID, on req: Request) async throws -> BankConnection {
        let exchanged = try await client.exchangePublicToken(request.publicToken, on: req)
        let encrypted = try req.tokenEncryptionService.encrypt(exchanged.accessToken, context: .bankPlaid)

        let connection = BankConnection(
            userId: userId,
            provider: kind.rawValue,
            institutionId: request.institutionId,
            institutionName: request.institutionName,
            providerItemId: exchanged.itemId,
            accessTokenEnc: encrypted,
            status: BankConnectionStatus.active.rawValue
        )
        try await connection.save(on: req.db)
        guard let connectionId = connection.id else {
            throw Abort(.internalServerError, reason: "Bank connection id missing.")
        }

        let accounts = try await client.accounts(accessToken: exchanged.accessToken, on: req)
        for account in accounts.accounts {
            try await upsertAccount(account, connectionId: connectionId, on: req.db)
        }
        return connection
    }

    func sync(connection: BankConnection, on req: Request) async throws -> BankSyncResult {
        guard let encrypted = connection.accessTokenEnc else {
            throw BankProviderError.notConfigured(.plaid)
        }
        let accessToken = try req.tokenEncryptionService.decrypt(encrypted, context: .bankPlaid)
        guard let connectionId = connection.id else {
            throw Abort(.internalServerError, reason: "Bank connection id missing.")
        }

        // Map provider account ids to our account rows for FK resolution.
        var accountsByProviderId = try await BankAccount.query(on: req.db)
            .filter(\.$connectionId == connectionId)
            .all()
            .reduce(into: [String: BankAccount]()) { $0[$1.providerAccountId] = $1 }

        var result = BankSyncResult()
        var cursor = connection.syncCursor
        var hasMore = true

        while hasMore {
            let page = try await client.transactionsSync(accessToken: accessToken, cursor: cursor, on: req)

            for tx in page.added + page.modified {
                guard let account = accountsByProviderId[tx.accountId] else {
                    // A new account appeared mid-sync; fetch and cache it.
                    let refreshed = try await client.accounts(accessToken: accessToken, on: req)
                    for account in refreshed.accounts {
                        try await upsertAccount(account, connectionId: connectionId, on: req.db)
                    }
                    accountsByProviderId = try await BankAccount.query(on: req.db)
                        .filter(\.$connectionId == connectionId)
                        .all()
                        .reduce(into: [String: BankAccount]()) { $0[$1.providerAccountId] = $1 }
                    guard accountsByProviderId[tx.accountId] != nil else { continue }
                    continue
                }
                let wasAdded = try await upsertTransaction(tx, account: account, userId: connection.userId, on: req.db)
                if wasAdded {
                    result.added += 1
                } else {
                    result.modified += 1
                }
            }

            for removed in page.removed {
                if let existing = try await BankTransaction.query(on: req.db)
                    .filter(\.$providerTxId == removed.transactionId)
                    .filter(\.$userId == connection.userId)
                    .first(),
                    existing.status == BankTransactionStatus.suggested.rawValue
                {
                    try await existing.delete(on: req.db)
                    result.removed += 1
                }
            }

            cursor = page.nextCursor
            hasMore = page.hasMore
        }

        connection.syncCursor = cursor
        connection.lastSyncedAt = Date()
        connection.lastSyncStatus = "ok"
        connection.lastSyncError = nil
        connection.status = BankConnectionStatus.active.rawValue
        try await connection.save(on: req.db)
        return result
    }

    func disconnect(connection: BankConnection, on req: Request) async throws {
        guard let encrypted = connection.accessTokenEnc else { return }
        let accessToken = try req.tokenEncryptionService.decrypt(encrypted, context: .bankPlaid)
        try? await client.removeItem(accessToken: accessToken, on: req)
    }

    // MARK: - Upserts

    private func upsertAccount(_ account: PlaidAccount, connectionId: UUID, on db: any Database) async throws {
        let existing = try await BankAccount.query(on: db)
            .filter(\.$connectionId == connectionId)
            .filter(\.$providerAccountId == account.accountId)
            .first()
        let row = existing ?? BankAccount(connectionId: connectionId, providerAccountId: account.accountId, name: account.name)
        row.name = account.name
        row.mask = account.mask
        row.type = account.type
        row.currency = account.balances?.isoCurrencyCode
        row.balance = account.balances?.current
        row.balanceAsOf = Date()
        try await row.save(on: db)
    }

    /// Returns true if a new row was inserted, false if an existing one updated.
    private func upsertTransaction(_ tx: PlaidTransaction, account: BankAccount, userId: UUID, on db: any Database) async throws -> Bool {
        guard let accountId = account.id else { return false }
        let occurredOn = Self.dateFormatter.date(from: tx.date) ?? Date()
        let merchant = tx.merchantName ?? tx.name
        let hash = Self.dedupeHash(accountId: accountId, date: tx.date, amount: tx.amount, description: merchant ?? "")

        if let existing = try await BankTransaction.query(on: db)
            .filter(\.$accountId == accountId)
            .filter(\.$providerTxId == tx.transactionId)
            .first()
        {
            // Never overwrite a row the user already acted on.
            if existing.status == BankTransactionStatus.suggested.rawValue {
                existing.amount = tx.amount
                existing.currency = tx.isoCurrencyCode
                existing.occurredOn = occurredOn
                existing.merchant = merchant
                existing.descriptionText = tx.name
                existing.pending = tx.pending
                existing.providerCategory = tx.category?.joined(separator: " / ")
                existing.dedupeHash = hash
                try await existing.save(on: db)
            }
            return false
        }

        let row = BankTransaction(
            accountId: accountId,
            userId: userId,
            providerTxId: tx.transactionId,
            dedupeHash: hash,
            amount: tx.amount,
            currency: tx.isoCurrencyCode,
            occurredOn: occurredOn,
            merchant: merchant,
            descriptionText: tx.name,
            pending: tx.pending,
            status: BankTransactionStatus.suggested.rawValue,
            providerCategory: tx.category?.joined(separator: " / ")
        )
        try await row.save(on: db)
        return true
    }

    static func dedupeHash(accountId: UUID, date: String, amount: Double, description: String) -> String {
        let normalized = "\(accountId.uuidString)|\(date)|\(String(format: "%.2f", amount))|\(description.lowercased().trimmingCharacters(in: .whitespaces))"
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
