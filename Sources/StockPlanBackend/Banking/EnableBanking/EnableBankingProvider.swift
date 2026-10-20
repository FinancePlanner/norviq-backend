import Crypto
import Fluent
import Foundation
import Redis
import StockPlanShared
import Vapor

/// Enable Banking driver (EU). AIS-only and read-only by design. Enable Banking
/// is the licensed AISP; we sign each call with the application's key. Uses a
/// hosted redirect (no SDK): `/auth` → bank SCA → our callback with `code` →
/// `/sessions`. Polls transactions within the PSD2 unattended limit
/// (≤4 calls/day/account), enforced via Redis.
struct EnableBankingProvider: BankProvider {
    let kind: BankProviderKind = .enablebanking
    let client: EnableBankingClient

    /// PSD2 caps unattended pulls at 4/day/account.
    private let dailyAccountCallBudget = 4
    /// Most banks allow 180 days; never ask for more.
    private let maxConsentValidity: TimeInterval = 180 * 86400
    /// Re-read a few days before the last sync so late-booked rows are caught.
    private let syncOverlap: TimeInterval = 3 * 86400

    // MARK: - SDK-style methods are unsupported (Enable Banking uses hosted links)

    func createLinkSession(userId _: UUID, on _: Request) async throws -> BankLinkSessionResponse {
        throw BankProviderError.unsupportedOperation
    }

    func exchange(_: BankExchangeRequest, userId _: UUID, on _: Request) async throws -> BankConnection {
        throw BankProviderError.unsupportedOperation
    }

    // MARK: - Hosted-link flow

    /// Enable Banking identifies a bank by (name, country), so the institution
    /// id handed to clients is `"<COUNTRY>:<name>"`.
    func listInstitutions(country: String, on req: Request) async throws -> [BankInstitutionResponse] {
        let aspsps = try await client.aspsps(country: country, on: req)
        return aspsps.map {
            BankInstitutionResponse(
                id: Self.institutionId(country: $0.country, name: $0.name),
                name: $0.name,
                bic: $0.bic,
                logoURL: $0.logo,
                country: $0.country,
                beta: $0.beta
            )
        }
    }

    func createHostedLink(userId: UUID, institutionId: String, redirectURI: String, on req: Request) async throws -> BankLinkSessionResponse {
        guard let (country, name) = Self.parseInstitutionId(institutionId) else {
            throw Abort(.badRequest, reason: "Unknown bank.")
        }
        let aspsps = try await client.aspsps(country: country, on: req)
        guard let aspsp = aspsps.first(where: { $0.name == name }) else {
            throw Abort(.badRequest, reason: "Unknown bank.")
        }

        let now = Date()
        let bankLimit = aspsp.maximumConsentValidity.map { TimeInterval($0) } ?? maxConsentValidity
        let validUntil = now.addingTimeInterval(min(bankLimit, maxConsentValidity))
        let state = Self.randomReference()
        let auth = try await client.startAuthorization(
            aspspName: aspsp.name,
            country: aspsp.country,
            validUntil: validUntil,
            state: state,
            redirectURL: client.config.redirectURL ?? Self.callbackURL(req: req),
            on: req
        )

        // `requisitionId` holds the authorization id until the callback swaps
        // in the session id.
        let flow = BankLinkFlow(
            userId: userId,
            provider: kind.rawValue,
            reference: state,
            requisitionId: auth.authorizationId ?? state,
            institutionId: institutionId,
            appRedirectURI: redirectURI,
            expiresAt: now.addingTimeInterval(1800)
        )
        try await flow.save(on: req.db)

        return BankLinkSessionResponse(provider: .enablebanking, linkToken: nil, hostedURL: auth.url, expiration: flow.expiresAt)
    }

    /// Called from the bank redirect; the one-time `code` arrives on the same
    /// request's query string.
    func completeHostedLink(reference: String, on req: Request) async throws -> BankConnection {
        let now = Date()
        guard let flow = try await BankLinkFlow.query(on: req.db)
            .filter(\.$reference == reference)
            .filter(\.$provider == kind.rawValue)
            .first(),
            flow.expiresAt > now
        else {
            throw Abort(.badRequest, reason: "Bank link is invalid or expired.")
        }

        // The code is single-use: a replayed callback can only find what the
        // first one created.
        if flow.usedAt != nil {
            if let existing = try await connection(providerItemId: flow.requisitionId, on: req.db) {
                return existing
            }
            throw Abort(.badRequest, reason: "Bank link is invalid or expired.")
        }

        let code = (req.query[String.self, at: "code"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            throw Abort(.badRequest, reason: "Missing authorization code.")
        }

        let session = try await client.createSession(code: code, on: req)
        guard !session.accounts.isEmpty else {
            throw Abort(.badRequest, reason: "No accounts were shared for this bank.")
        }
        let consentExpiresAt = session.access?.validUntil.flatMap { Self.parseTimestamp($0) }
            ?? now.addingTimeInterval(90 * 86400)

        let connection: BankConnection
        if let previous = try await reconsentTarget(userId: flow.userId, accounts: session.accounts, on: req.db) {
            // Re-consent for accounts we already hold: keep the connection (and
            // its transaction history) and point it at the new session.
            previous.providerItemId = session.sessionId
            previous.status = BankConnectionStatus.active.rawValue
            previous.consentExpiresAt = consentExpiresAt
            previous.lastSyncStatus = nil
            previous.lastSyncError = nil
            try await previous.save(on: req.db)
            connection = previous
        } else {
            connection = BankConnection(
                userId: flow.userId,
                provider: kind.rawValue,
                institutionId: flow.institutionId,
                institutionName: session.aspsp?.name ?? flow.institutionId.flatMap { Self.parseInstitutionId($0)?.name },
                providerItemId: session.sessionId,
                accessTokenEnc: nil,
                status: BankConnectionStatus.active.rawValue,
                consentExpiresAt: consentExpiresAt
            )
            try await connection.save(on: req.db)
        }
        guard let connectionId = connection.id else {
            throw Abort(.internalServerError, reason: "Bank connection id missing.")
        }

        try await upsertAccounts(session.accounts, connectionId: connectionId, on: req.db)

        flow.requisitionId = session.sessionId
        flow.usedAt = now
        try await flow.save(on: req.db)

        // Many banks give full history only right after consent; backfill now.
        _ = try? await sync(connection: connection, on: req)
        return connection
    }

    // MARK: - Sync

    func sync(connection: BankConnection, on req: Request) async throws -> BankSyncResult {
        guard let connectionId = connection.id else {
            throw Abort(.internalServerError, reason: "Bank connection id missing.")
        }
        if let expiry = connection.consentExpiresAt, expiry <= Date() {
            try await markReauthRequired(connection, status: "consent_expired", on: req.db)
            throw Abort(.forbidden, reason: "Bank consent expired. Reconnect to keep syncing.")
        }

        let dateFrom = connection.lastSyncedAt.map { $0.addingTimeInterval(-syncOverlap) }
        let accounts = try await BankAccount.query(on: req.db).filter(\.$connectionId == connectionId).all()

        var result = BankSyncResult()
        for account in accounts {
            guard let accountId = account.id else { continue }
            guard try await consumeDailyBudget(accountUID: account.providerAccountId, on: req) else {
                req.logger.info("enablebanking daily budget exhausted account=\(accountId)")
                continue
            }

            let transactions: [EBTransaction]
            do {
                transactions = try await client.transactions(
                    accountUID: account.providerAccountId,
                    dateFrom: dateFrom.map { Self.dateFormatter.string(from: $0) },
                    on: req
                )
            } catch let error as EnableBankingAPIError where error.requiresReauth {
                try await markReauthRequired(connection, status: "consent_revoked", on: req.db)
                throw Abort(.forbidden, reason: "Bank consent expired. Reconnect to keep syncing.")
            }

            result.removed += try await clearPendingSuggestions(accountId: accountId, since: dateFrom, on: req.db)
            for tx in transactions where Self.syncedStatuses.contains(tx.status) {
                if try await upsert(tx, account: account, userId: connection.userId, on: req.db) {
                    result.added += 1
                } else {
                    result.modified += 1
                }
            }
        }

        connection.lastSyncedAt = Date()
        connection.lastSyncStatus = "ok"
        connection.lastSyncError = nil
        try await connection.save(on: req.db)
        return result
    }

    func disconnect(connection: BankConnection, on req: Request) async throws {
        try await client.deleteSession(id: connection.providerItemId, on: req)
    }

    // MARK: - Transactions

    /// Booked and pending only; cancelled, rejected and scheduled rows never
    /// became spending.
    static let syncedStatuses: Set<String> = ["BOOK", "PDNG"]

    /// Inserts or refreshes one transaction. Returns true when a row was added.
    /// Keyed on `entry_reference` (unique and immutable per account); banks
    /// that omit it fall back to a content hash. `transaction_id` is never
    /// used — it can change between fetches.
    func upsert(_ tx: EBTransaction, account: BankAccount, userId: UUID, on db: any Database) async throws -> Bool {
        guard let accountId = account.id else { return false }
        let magnitude = abs(Double(tx.transactionAmount.amount) ?? 0)
        let isDebit = tx.creditDebitIndicator.uppercased() == "DBIT"
        // Same sign convention as GoCardless: money out is negative.
        let amount = isDebit ? -magnitude : magnitude
        let pending = tx.status == "PDNG"
        let dateString = tx.bookingDate ?? tx.transactionDate ?? tx.valueDate ?? ""
        let occurredOn = Self.dateFormatter.date(from: dateString) ?? Date()
        let description = tx.remittanceInformation?
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let counterparty = isDebit ? tx.creditor?.name : tx.debtor?.name
        let merchant = bankingTrimmedNonEmpty(counterparty) ?? bankingTrimmedNonEmpty(description)
        let dedupeHash = Self.hash(
            accountKey: account.identificationHash ?? accountId.uuidString,
            date: dateString,
            amount: amount,
            description: merchant ?? ""
        )
        let providerTxId = bankingTrimmedNonEmpty(tx.entryReference) ?? dedupeHash

        if let existing = try await BankTransaction.query(on: db)
            .filter(\.$accountId == accountId)
            .filter(\.$providerTxId == providerTxId)
            .first()
        {
            if existing.status == BankTransactionStatus.suggested.rawValue {
                existing.amount = amount
                existing.currency = tx.transactionAmount.currency
                existing.occurredOn = occurredOn
                existing.merchant = merchant
                existing.descriptionText = bankingTrimmedNonEmpty(description)
                existing.pending = pending
                existing.dedupeHash = dedupeHash
                existing.providerCategory = tx.merchantCategoryCode
                try await existing.save(on: db)
            }
            return false
        }

        let row = BankTransaction(
            accountId: accountId,
            userId: userId,
            providerTxId: providerTxId,
            dedupeHash: dedupeHash,
            amount: amount,
            currency: tx.transactionAmount.currency,
            occurredOn: occurredOn,
            merchant: merchant,
            descriptionText: bankingTrimmedNonEmpty(description),
            pending: pending,
            status: BankTransactionStatus.suggested.rawValue,
            providerCategory: tx.merchantCategoryCode
        )
        try await row.save(on: db)
        return true
    }

    /// Pending rows rarely keep their identity once booked, so un-reviewed
    /// pending suggestions inside the fetched window are dropped and rebuilt
    /// from the fresh pull. Reviewed rows are never touched.
    private func clearPendingSuggestions(accountId: UUID, since: Date?, on db: any Database) async throws -> Int {
        var query = BankTransaction.query(on: db)
            .filter(\.$accountId == accountId)
            .filter(\.$pending == true)
            .filter(\.$status == BankTransactionStatus.suggested.rawValue)
        if let since {
            query = query.filter(\.$occurredOn >= Calendar(identifier: .gregorian).startOfDay(for: since))
        }
        let stale = try await query.all()
        try await stale.delete(on: db)
        return stale.count
    }

    // MARK: - Accounts

    /// An existing connection of this user that already holds one of the
    /// session's accounts (matched by the cross-session identification hash).
    private func reconsentTarget(userId: UUID, accounts: [EBSessionAccount], on db: any Database) async throws -> BankConnection? {
        let hashes = accounts.compactMap(\.identificationHash)
        guard !hashes.isEmpty else { return nil }
        let connections = try await BankConnection.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$provider == kind.rawValue)
            .all()
        let connectionIds = connections.compactMap(\.id)
        guard !connectionIds.isEmpty else { return nil }
        guard let match = try await BankAccount.query(on: db)
            .filter(\.$connectionId ~~ connectionIds)
            .filter(\.$identificationHash ~~ hashes)
            .first()
        else {
            return nil
        }
        return connections.first { $0.id == match.connectionId }
    }

    private func upsertAccounts(_ accounts: [EBSessionAccount], connectionId: UUID, on db: any Database) async throws {
        let existing = try await BankAccount.query(on: db).filter(\.$connectionId == connectionId).all()
        for remote in accounts {
            let account = existing.first { local in
                if let hash = remote.identificationHash, local.identificationHash == hash {
                    return true
                }
                return local.providerAccountId == remote.uid
            } ?? BankAccount(connectionId: connectionId, providerAccountId: remote.uid, name: "Account")
            // The uid is session-scoped, so always take the new one.
            account.providerAccountId = remote.uid
            account.identificationHash = remote.identificationHash ?? account.identificationHash
            account.name = bankingTrimmedNonEmpty(remote.name) ?? bankingTrimmedNonEmpty(remote.product) ?? account.name
            account.mask = remote.accountId?.iban.map { String($0.suffix(4)) } ?? account.mask
            account.currency = remote.currency ?? account.currency
            account.type = remote.cashAccountType ?? account.type
            try await account.save(on: db)
        }
    }

    // MARK: - Helpers

    private func connection(providerItemId: String, on db: any Database) async throws -> BankConnection? {
        try await BankConnection.query(on: db)
            .filter(\.$provider == kind.rawValue)
            .filter(\.$providerItemId == providerItemId)
            .first()
    }

    private func markReauthRequired(_ connection: BankConnection, status: String, on db: any Database) async throws {
        connection.status = BankConnectionStatus.reauthRequired.rawValue
        connection.lastSyncStatus = status
        try await connection.save(on: db)
    }

    /// Returns true if a call is allowed under the per-account daily budget.
    /// When Redis is unavailable, allows the call (fails open in dev).
    private func consumeDailyBudget(accountUID: String, on req: Request) async throws -> Bool {
        guard req.application.redis.configuration != nil else { return true }
        let key = RedisKey("enablebanking:budget:\(accountUID)")
        let count = try await req.redis.increment(key).get()
        if count == 1 {
            _ = try? await req.redis.expire(key, after: .hours(24)).get()
        }
        return count <= dailyAccountCallBudget
    }

    static func institutionId(country: String, name: String) -> String {
        "\(country.uppercased()):\(name)"
    }

    static func parseInstitutionId(_ id: String) -> (country: String, name: String)? {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].count == 2, !parts[1].isEmpty else { return nil }
        return (parts[0].uppercased(), parts[1])
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    static func hash(accountKey: String, date: String, amount: Double, description: String) -> String {
        let normalized = "\(accountKey)|\(date)|\(String(format: "%.2f", amount))|\(description.lowercased().trimmingCharacters(in: .whitespaces))"
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomReference() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return "nvq-" + String((0 ..< 32).map { _ in alphabet.randomElement()! })
    }

    private static func callbackURL(req: Request) throws -> String {
        let scheme = req.headers.first(name: "X-Forwarded-Proto") ?? "https"
        guard let host = req.headers.first(name: .host), !host.isEmpty else {
            throw Abort(.internalServerError, reason: "Missing request host.")
        }
        return "\(scheme)://\(host)/v1/banks/enablebanking/callback"
    }
}
