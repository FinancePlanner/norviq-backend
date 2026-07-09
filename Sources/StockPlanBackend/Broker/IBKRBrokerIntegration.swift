import Fluent
import Foundation
import Vapor

struct IBKRBrokerGatewayClient {
    let baseURL: String
    let defaultCurrency: String
    let accessToken: String?

    init(
        baseURL: String = Environment.get("IBKR_API_BASE_URL") ?? "http://localhost:5000/v1/api",
        defaultCurrency: String = Environment.get("MARKET_DEFAULT_CURRENCY") ?? "USD",
        accessToken: String? = nil
    ) {
        self.baseURL = baseURL
        self.defaultCurrency = defaultCurrency
        self.accessToken = accessToken
    }

    func checkAuthStatus(on req: Request) async throws -> Bool {
        let response = try await get(path: "/iserver/auth/status", on: req)
        guard response.status == .ok else { return false }
        if let status = try? response.content.decode(IBKRAuthStatus.self) {
            return status.authenticated == true
        }
        return false
    }

    func reauthenticate(on req: Request) async throws {
        let response = try await post(path: "/iserver/reauthenticate", on: req)
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "IBKR reauthentication failed with status \(response.status.code).")
        }
    }

    func requirePrimaryAccount(on req: Request) async throws -> IBKRBrokerAccount {
        let accounts = try await fetchAccounts(on: req)
        guard let account = accounts.first else {
            throw Abort(.badGateway, reason: "IBKR did not return any accounts.")
        }
        return account
    }

    func fetchPositions(accountID: String, on req: Request) async throws -> [IBKRBrokerPosition] {
        let response = try await withRetry(on: req) {
            try await get(path: "/portfolio/\(accountID)/positions/0", on: req)
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "IBKR positions request failed with status \(response.status.code).")
        }

        if let positions = try? response.content.decode([IBKRBrokerPositionPayload].self) {
            return positions.compactMap { $0.toPosition(defaultCurrency: defaultCurrency) }
        }

        if let envelope = try? response.content.decode(IBKRBrokerPositionsEnvelope.self) {
            return envelope.positions.compactMap { $0.toPosition(defaultCurrency: defaultCurrency) }
        }

        throw Abort(.badGateway, reason: "IBKR positions response format was not recognized.")
    }

    func fetchTransactions(accountID: String, from: Date, to: Date, on req: Request) async throws -> [IBKRBrokerTransaction] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let fromStr = formatter.string(from: from)
        let toStr = formatter.string(from: to)

        let response = try await withRetry(on: req) {
            try await get(path: "/pa/transactions?accountId=\(accountID)&from=\(fromStr)&to=\(toStr)", on: req)
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "IBKR transactions request failed with status \(response.status.code).")
        }

        if let transactions = try? response.content.decode([IBKRBrokerTransactionPayload].self) {
            return transactions.compactMap { $0.toTransaction() }
        }

        if let envelope = try? response.content.decode(IBKRBrokerTransactionsEnvelope.self) {
            return envelope.transactions.compactMap { $0.toTransaction() }
        }

        return []
    }

    func fetchCashBalances(accountID: String, on req: Request) async throws -> [IBKRBrokerCashBalance] {
        let response = try await withRetry(on: req) {
            try await get(path: "/portfolio/\(accountID)/ledger", on: req)
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "IBKR cash balances request failed with status \(response.status.code).")
        }

        if let ledger = try? response.content.decode(IBKRBrokerLedgerPayload.self) {
            return ledger.toCashBalances()
        }

        return []
    }

    func fetchDividends(accountID: String, from: Date, to: Date, on req: Request) async throws -> [IBKRBrokerDividend] {
        let transactions = try await fetchTransactions(accountID: accountID, from: from, to: to, on: req)
        return transactions.compactMap { transaction -> IBKRBrokerDividend? in
            guard transaction.type == "DIV" || transaction.type == "DIVIDEND" else { return nil }
            return IBKRBrokerDividend(
                externalID: transaction.externalID,
                symbol: transaction.symbol,
                amount: transaction.amount,
                currency: transaction.currency,
                date: transaction.date
            )
        }
    }

    private func fetchAccounts(on req: Request) async throws -> [IBKRBrokerAccount] {
        let response = try await withRetry(on: req) {
            try await get(path: "/portfolio/accounts", on: req)
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "IBKR accounts request failed with status \(response.status.code).")
        }

        if let accounts = try? response.content.decode([IBKRBrokerAccountPayload].self) {
            return accounts.compactMap { $0.toAccount() }
        }

        if let envelope = try? response.content.decode(IBKRBrokerAccountsEnvelope.self) {
            return envelope.accounts.compactMap { $0.toAccount() }
        }

        throw Abort(.badGateway, reason: "IBKR accounts response format was not recognized.")
    }

    private func withRetry<T>(on req: Request, maxRetries: Int = 3, operation: @escaping () async throws -> T) async throws -> T {
        var lastError: (any Error)?
        for attempt in 0 ..< maxRetries {
            do {
                if attempt > 0, accessToken == nil {
                    let isAuthenticated = try await checkAuthStatus(on: req)
                    if !isAuthenticated {
                        try await reauthenticate(on: req)
                    }
                }
                return try await operation()
            } catch {
                lastError = error
                if attempt < maxRetries - 1 {
                    let delay = Double(1 << attempt)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        throw lastError ?? Abort(.badGateway, reason: "IBKR request failed after \(maxRetries) retries.")
    }

    private func get(path: String, on req: Request) async throws -> ClientResponse {
        try await req.client.get(URI(string: makeURL(path: path))) { request in
            addAuthorizationHeader(to: &request.headers)
        }
    }

    private func post(path: String, on req: Request) async throws -> ClientResponse {
        try await req.client.post(URI(string: makeURL(path: path))) { request in
            addAuthorizationHeader(to: &request.headers)
        }
    }

    private func addAuthorizationHeader(to headers: inout HTTPHeaders) {
        guard let accessToken, !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        headers.bearerAuthorization = .init(token: accessToken)
    }

    private func makeURL(path: String) -> String {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return base + "/" + normalizedPath
    }
}

struct IBKRBrokerAccount {
    let externalID: String
    let displayName: String?
}

struct IBKRBrokerPosition {
    let symbol: String
    let quantity: Double
    let averageCost: Double
    let currency: String
    let conid: String?
}

struct IBKRBrokerTransaction {
    let externalID: String
    let symbol: String
    let type: String
    let quantity: Double
    let amount: Double
    let currency: String
    let date: Date
}

struct IBKRBrokerCashBalance {
    let currency: String
    let amount: Double
}

struct IBKRBrokerDividend {
    let externalID: String?
    let symbol: String
    let amount: Double
    let currency: String
    let date: Date
}

private struct IBKRAuthStatus: Decodable {
    let authenticated: Bool?
}

struct IBKRBrokerSyncService {
    private let gatewayClient: IBKRBrokerGatewayClient

    init(gatewayClient: IBKRBrokerGatewayClient) {
        self.gatewayClient = gatewayClient
    }

    func sync(connection: BrokerConnection, userId: UUID, on req: Request) async throws -> BrokerSyncResponse {
        let account = try await resolveGatewayAccount(for: connection, on: req)
        let positions = try await gatewayClient.fetchPositions(accountID: account.externalID, on: req)
            .filter { $0.quantity > 0 }

        guard let connectionID = connection.id else {
            throw Abort(.internalServerError, reason: "Broker connection id missing.")
        }

        let portfolioListId: UUID = if let existingPortfolioListId = connection.portfolioListId {
            existingPortfolioListId
        } else {
            try await ensureDefaultPortfolioListId(userId: userId, on: req.db)
        }
        let sourceAccount = try await resolveImportAccount(
            account: account,
            provider: connection.provider,
            userId: userId,
            on: req.db
        )
        let sourceAccountID = try sourceAccount.requireID()
        let existingSymbols = try await existingImportedSymbols(
            provider: connection.provider,
            sourceAccountId: sourceAccountID,
            userId: userId,
            on: req.db
        )

        var inserted = 0
        var updated = 0
        var seenSymbols = Set<String>()

        for position in positions {
            let symbol = position.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !symbol.isEmpty else { continue }
            let didExist = existingSymbols.contains(symbol)
            try await upsertPosition(
                symbol: symbol,
                position: position,
                provider: connection.provider,
                sourceAccountId: sourceAccountID,
                portfolioListId: portfolioListId,
                userId: userId,
                on: req
            )
            seenSymbols.insert(symbol)
            if didExist {
                updated += 1
            } else {
                inserted += 1
            }
        }

        let removed = try await removeStaleImportedSymbols(
            existingSymbols: existingSymbols,
            seenSymbols: seenSymbols,
            provider: connection.provider,
            sourceAccountId: sourceAccountID,
            userId: userId,
            on: req.db
        )

        let lastSyncDate = connection.lastSyncedAt ?? Date().addingTimeInterval(-30 * 24 * 3600)
        _ = try await syncTransactions(
            accountID: account.externalID,
            sourceAccountId: sourceAccountID,
            from: lastSyncDate,
            to: Date(),
            on: req
        )

        _ = try await syncCashBalances(
            accountID: account.externalID,
            sourceAccountId: sourceAccountID,
            on: req
        )

        _ = try await syncDividends(
            accountID: account.externalID,
            sourceAccountId: sourceAccountID,
            from: lastSyncDate,
            to: Date(),
            on: req
        )

        connection.externalId = account.externalID
        connection.displayName = account.displayName ?? connection.displayName
        connection.status = "connected"
        connection.statusDetail = nil
        connection.connectedAt = connection.connectedAt ?? Date()
        connection.lastSyncedAt = Date()
        connection.portfolioListId = portfolioListId
        connection.updatedAt = Date()
        try await connection.save(on: req.db)

        return BrokerSyncResponse(
            runId: connectionID.uuidString,
            status: "completed",
            inserted: inserted,
            updated: updated,
            removed: removed
        )
    }

    private func syncTransactions(
        accountID: String,
        sourceAccountId: UUID,
        from: Date,
        to: Date,
        on req: Request
    ) async throws -> Int {
        let transactions = try await gatewayClient.fetchTransactions(
            accountID: accountID,
            from: from,
            to: to,
            on: req
        )

        var syncedCount = 0
        for ibkrTransaction in transactions {
            let exists = try await Transaction.query(on: req.db)
                .filter(\.$accountId == sourceAccountId)
                .filter(\.$externalId == ibkrTransaction.externalID)
                .first() != nil

            if exists {
                continue
            }

            let instrument = try await requireInstrument(
                symbol: ibkrTransaction.symbol,
                conid: nil,
                currency: ibkrTransaction.currency,
                on: req,
                db: req.db
            )
            let instrumentID = try instrument.requireID()

            let transaction = Transaction(
                accountId: sourceAccountId,
                instrumentId: instrumentID,
                externalId: ibkrTransaction.externalID,
                type: mapTransactionType(ibkrTransaction.type),
                quantity: ibkrTransaction.quantity,
                price: ibkrTransaction.quantity != 0 ? abs(ibkrTransaction.amount / ibkrTransaction.quantity) : 0,
                currency: ibkrTransaction.currency,
                tradeDate: ibkrTransaction.date,
                settleDate: ibkrTransaction.date
            )
            try await transaction.save(on: req.db)
            // Business metric: transactions created via IBKR sync
            req.application.businessMetrics.incrementTransactionsCreated()
            syncedCount += 1
        }

        return syncedCount
    }

    private func syncCashBalances(
        accountID: String,
        sourceAccountId: UUID,
        on req: Request
    ) async throws -> Int {
        let balances = try await gatewayClient.fetchCashBalances(accountID: accountID, on: req)

        try await CashBalance.query(on: req.db)
            .filter(\.$accountId == sourceAccountId)
            .delete()

        var syncedCount = 0
        for ibkrBalance in balances {
            let balance = CashBalance(
                accountId: sourceAccountId,
                currency: ibkrBalance.currency,
                balance: ibkrBalance.amount,
                asOf: Date()
            )
            try await balance.save(on: req.db)
            syncedCount += 1
        }
        return syncedCount
    }

    private func syncDividends(
        accountID: String,
        sourceAccountId: UUID,
        from: Date,
        to: Date,
        on req: Request
    ) async throws -> Int {
        let dividends = try await gatewayClient.fetchDividends(accountID: accountID, from: from, to: to, on: req)

        var syncedCount = 0
        for ibkrDividend in dividends {
            if let externalID = ibkrDividend.externalID {
                let exists = try await Dividend.query(on: req.db)
                    .filter(\.$accountId == sourceAccountId)
                    .filter(\.$externalId == externalID)
                    .first() != nil
                if exists {
                    continue
                }
            }

            let instrument = try await requireInstrument(
                symbol: ibkrDividend.symbol,
                conid: nil,
                currency: ibkrDividend.currency,
                on: req,
                db: req.db
            )
            let instrumentID = try instrument.requireID()

            let dividend = Dividend(
                accountId: sourceAccountId,
                instrumentId: instrumentID,
                externalId: ibkrDividend.externalID,
                amount: ibkrDividend.amount,
                currency: ibkrDividend.currency,
                payDate: ibkrDividend.date
            )
            try await dividend.save(on: req.db)
            syncedCount += 1
        }
        return syncedCount
    }

    private func mapTransactionType(_ ibkrType: String) -> String {
        switch ibkrType.uppercased() {
        case "BUY", "BOT": "BUY"
        case "SELL", "SLD": "SELL"
        case "DIV", "DIVIDEND": "DIVIDEND"
        case "INTEREST": "INTEREST"
        case "FEE": "FEE"
        case "DEPOSIT": "DEPOSIT"
        case "WITHDRAWAL": "WITHDRAWAL"
        default: ibkrType.uppercased()
        }
    }
}

private extension IBKRBrokerSyncService {
    func resolveGatewayAccount(for connection: BrokerConnection, on req: Request) async throws -> IBKRBrokerAccount {
        let gatewayAccount = try await gatewayClient.requirePrimaryAccount(on: req)
        if let externalID = connection.externalId,
           !externalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           gatewayAccount.externalID != externalID
        {
            req.logger.warning("broker.ibkr account_mismatch stored=\(externalID) live=\(gatewayAccount.externalID)")
        }
        return gatewayAccount
    }

    func resolveImportAccount(
        account: IBKRBrokerAccount,
        provider: String,
        userId: UUID,
        on db: any Database
    ) async throws -> Account {
        if let existing = try await Account.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$broker == provider)
            .filter(\.$externalId == account.externalID)
            .first()
        {
            existing.displayName = account.displayName ?? existing.displayName
            existing.updatedAt = Date()
            try await existing.save(on: db)
            return existing
        }

        let created = Account(
            userId: userId,
            externalId: account.externalID,
            broker: provider,
            displayName: account.displayName,
            baseCurrency: gatewayClient.defaultCurrency
        )
        try await created.save(on: db)
        return created
    }

    func existingImportedSymbols(
        provider: String,
        sourceAccountId: UUID,
        userId: UUID,
        on db: any Database
    ) async throws -> Set<String> {
        let stocks = try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$sourceProvider == provider)
            .filter(\.$sourceAccountId == sourceAccountId)
            .all()
        return Set(stocks.map(\.symbol))
    }

    func upsertPosition(
        symbol: String,
        position: IBKRBrokerPosition,
        provider: String,
        sourceAccountId: UUID,
        portfolioListId: UUID,
        userId: UUID,
        on req: Request
    ) async throws {
        try await req.db.transaction { db in
            let instrument = try await requireInstrument(symbol: symbol, conid: position.conid, currency: position.currency, on: req, db: db)

            let existingStocks = try await Stock.query(on: db)
                .filter(\.$userId == userId)
                .filter(\.$sourceProvider == provider)
                .filter(\.$sourceAccountId == sourceAccountId)
                .filter(\.$symbol == symbol)
                .all()
            for stock in existingStocks {
                try await stock.delete(on: db)
            }

            let instrumentID = try instrument.requireID()
            let existingLots = try await Lot.query(on: db)
                .filter(\.$accountId == sourceAccountId)
                .filter(\.$instrumentId == instrumentID)
                .all()
            for lot in existingLots {
                try await lot.delete(on: db)
            }

            if let existingPosition = try await Position.query(on: db)
                .filter(\.$accountId == sourceAccountId)
                .filter(\.$instrumentId == instrumentID)
                .first()
            {
                try await existingPosition.delete(on: db)
            }

            let quantity = max(position.quantity, 0)
            let averageCost = max(position.averageCost, 0)
            let now = Date()

            let lot = Lot(
                accountId: sourceAccountId,
                instrumentId: instrumentID,
                openDate: now,
                openQuantity: quantity,
                remainingQuantity: quantity,
                openPrice: averageCost,
                currency: position.currency,
                status: "open"
            )
            try await lot.save(on: db)

            let dbPosition = Position(
                accountId: sourceAccountId,
                instrumentId: instrumentID,
                quantity: quantity,
                averageCost: averageCost,
                currency: position.currency
            )
            try await dbPosition.save(on: db)

            let stock = Stock(
                userId: userId,
                portfolioListId: portfolioListId,
                symbol: symbol,
                shares: quantity,
                buyPrice: averageCost,
                buyDate: now,
                notes: nil,
                category: .stock,
                sourceProvider: provider,
                sourceAccountId: sourceAccountId
            )
            try await stock.save(on: db)
        }
    }

    func requireInstrument(
        symbol: String,
        conid: String?,
        currency: String,
        on req: Request,
        db: any Database
    ) async throws -> Instrument {
        if let existing = try await Instrument.query(on: db)
            .filter(\.$symbol == symbol)
            .first()
        {
            return existing
        }

        let candidates = try await req.application.marketDataService.search(query: symbol, on: req)
        if let matched = candidates.first(where: { $0.symbol == symbol }) ?? candidates.first {
            let instrument = Instrument(
                conid: matched.conid,
                symbol: matched.symbol,
                exchange: matched.exchange,
                currency: matched.currency,
                name: matched.name
            )
            try await instrument.save(on: db)
            return instrument
        }

        let instrument = Instrument(
            conid: conid ?? symbol,
            symbol: symbol,
            exchange: "UNKNOWN",
            currency: currency,
            name: symbol
        )
        try await instrument.save(on: db)
        return instrument
    }

    func removeStaleImportedSymbols(
        existingSymbols: Set<String>,
        seenSymbols: Set<String>,
        provider: String,
        sourceAccountId: UUID,
        userId: UUID,
        on db: any Database
    ) async throws -> Int {
        let staleSymbols = existingSymbols.subtracting(seenSymbols)
        guard !staleSymbols.isEmpty else { return 0 }

        for symbol in staleSymbols {
            let stocks = try await Stock.query(on: db)
                .filter(\.$userId == userId)
                .filter(\.$sourceProvider == provider)
                .filter(\.$sourceAccountId == sourceAccountId)
                .filter(\.$symbol == symbol)
                .all()
            for stock in stocks {
                try await stock.delete(on: db)
            }

            if let instrument = try await Instrument.query(on: db)
                .filter(\.$symbol == symbol)
                .first(),
                let instrumentID = instrument.id
            {
                let lots = try await Lot.query(on: db)
                    .filter(\.$accountId == sourceAccountId)
                    .filter(\.$instrumentId == instrumentID)
                    .all()
                for lot in lots {
                    try await lot.delete(on: db)
                }

                if let position = try await Position.query(on: db)
                    .filter(\.$accountId == sourceAccountId)
                    .filter(\.$instrumentId == instrumentID)
                    .first()
                {
                    try await position.delete(on: db)
                }
            }
        }

        return staleSymbols.count
    }

    func ensureDefaultPortfolioListId(userId: UUID, on db: any Database) async throws -> UUID {
        if let list = try await PortfolioList.query(on: db)
            .filter(\.$userId == userId)
            .first()
        {
            return try list.requireID()
        }
        let list = PortfolioList(userId: userId, name: "Default")
        try await list.save(on: db)
        return try list.requireID()
    }
}

private struct IBKRBrokerAccountsEnvelope: Decodable {
    let accounts: [IBKRBrokerAccountPayload]
}

private struct IBKRBrokerAccountPayload: Decodable {
    let id: BrokerLossyValue?
    let accountId: BrokerLossyValue?
    let accountID: BrokerLossyValue?
    let accountTitle: String?
    let displayName: String?
    let alias: String?

    func toAccount() -> IBKRBrokerAccount? {
        let externalID =
            id?.stringValue
                ?? accountId?.stringValue
                ?? accountID?.stringValue
        guard let externalID, !externalID.isEmpty else { return nil }

        let displayName = [displayName, accountTitle, alias]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        return IBKRBrokerAccount(externalID: externalID, displayName: displayName)
    }
}

private struct IBKRBrokerPositionsEnvelope: Decodable {
    let positions: [IBKRBrokerPositionPayload]

    enum CodingKeys: String, CodingKey {
        case positions = "data"
    }
}

private struct IBKRBrokerPositionPayload: Decodable {
    let ticker: String?
    let symbol: String?
    let contractDesc: String?
    let position: BrokerLossyValue?
    let qty: BrokerLossyValue?
    let avgPrice: BrokerLossyValue?
    let averagePrice: BrokerLossyValue?
    let avgCost: BrokerLossyValue?
    let currency: String?
    let conid: BrokerLossyValue?

    func toPosition(defaultCurrency: String) -> IBKRBrokerPosition? {
        let resolvedSymbol = [ticker, symbol, contractDesc]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .first(where: { !$0.isEmpty })
        guard let resolvedSymbol else { return nil }

        let quantity = position?.doubleValue ?? qty?.doubleValue ?? 0
        let averageCost = avgPrice?.doubleValue ?? averagePrice?.doubleValue ?? avgCost?.doubleValue ?? 0
        let resolvedCurrency = currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return IBKRBrokerPosition(
            symbol: resolvedSymbol,
            quantity: quantity,
            averageCost: averageCost,
            currency: (resolvedCurrency?.isEmpty == false ? resolvedCurrency! : defaultCurrency),
            conid: conid?.stringValue
        )
    }
}

private struct BrokerLossyValue: Decodable {
    let stringValue: String

    var doubleValue: Double? {
        Double(stringValue.replacingOccurrences(of: ",", with: ""))
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            stringValue = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        if let int = try? container.decode(Int.self) {
            stringValue = String(int)
            return
        }
        if let double = try? container.decode(Double.self) {
            stringValue = String(double)
            return
        }
        if let bool = try? container.decode(Bool.self) {
            stringValue = bool ? "true" : "false"
            return
        }
        throw DecodingError.typeMismatch(
            String.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unsupported lossy value.")
        )
    }
}

private struct IBKRBrokerTransactionsEnvelope: Decodable {
    let transactions: [IBKRBrokerTransactionPayload]
}

private struct IBKRBrokerTransactionPayload: Decodable {
    let transactionID: BrokerLossyValue?
    let id: BrokerLossyValue?
    let symbol: String?
    let type: String?
    let quantity: BrokerLossyValue?
    let amount: BrokerLossyValue?
    let currency: String?
    let date: String?
    let tradeDate: String?

    func toTransaction() -> IBKRBrokerTransaction? {
        let externalID = transactionID?.stringValue ?? id?.stringValue
        guard let externalID, !externalID.isEmpty else { return nil }
        guard let symbol, !symbol.isEmpty else { return nil }
        guard let type, !type.isEmpty else { return nil }

        let dateStr = date ?? tradeDate ?? ""
        let formatter = ISO8601DateFormatter()
        let parsedDate = formatter.date(from: dateStr) ?? Date()

        return IBKRBrokerTransaction(
            externalID: externalID,
            symbol: symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            type: type.uppercased(),
            quantity: quantity?.doubleValue ?? 0,
            amount: amount?.doubleValue ?? 0,
            currency: currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "USD",
            date: parsedDate
        )
    }
}

private struct IBKRBrokerLedgerPayload: Decodable {
    let BASE: [String: BrokerLossyValue]?
    let USD: [String: BrokerLossyValue]?
    let EUR: [String: BrokerLossyValue]?
    let GBP: [String: BrokerLossyValue]?
    let JPY: [String: BrokerLossyValue]?
    let CHF: [String: BrokerLossyValue]?
    let CAD: [String: BrokerLossyValue]?
    let AUD: [String: BrokerLossyValue]?

    func toCashBalances() -> [IBKRBrokerCashBalance] {
        var balances: [IBKRBrokerCashBalance] = []
        let currencies = [
            ("USD", USD),
            ("EUR", EUR),
            ("GBP", GBP),
            ("JPY", JPY),
            ("CHF", CHF),
            ("CAD", CAD),
            ("AUD", AUD),
        ]

        for (currency, ledger) in currencies {
            guard let ledger else { continue }
            if let cashBalance = ledger["cashbalance"]?.doubleValue ?? ledger["totalcashvalue"]?.doubleValue {
                balances.append(IBKRBrokerCashBalance(currency: currency, amount: cashBalance))
            }
        }

        if let base = BASE, let cashBalance = base["cashbalance"]?.doubleValue ?? base["totalcashvalue"]?.doubleValue {
            balances.append(IBKRBrokerCashBalance(currency: "BASE", amount: cashBalance))
        }

        return balances
    }
}
