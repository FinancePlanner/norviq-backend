import Foundation
import StockPlanShared

extension BankAccountResponse {
    init(from model: BankAccount) throws {
        guard let id = model.id else { throw BankMappingError.missingID }
        self.init(
            id: id.uuidString,
            name: model.name,
            mask: model.mask,
            currency: model.currency,
            type: model.type,
            balance: model.balance
        )
    }
}

extension BankConnectionResponse {
    init(from model: BankConnection, accounts: [BankAccount]) throws {
        guard let id = model.id else { throw BankMappingError.missingID }
        try self.init(
            id: id.uuidString,
            provider: BankProviderKind(rawValue: model.provider) ?? .plaid,
            institutionName: model.institutionName,
            status: BankConnectionStatus(rawValue: model.status) ?? .active,
            consentExpiresAt: model.consentExpiresAt,
            lastSyncedAt: model.lastSyncedAt,
            accounts: accounts.map { try BankAccountResponse(from: $0) }
        )
    }
}

extension BankTransactionResponse {
    init(from model: BankTransaction, possibleDuplicate: Bool) throws {
        guard let id = model.id else { throw BankMappingError.missingID }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        self.init(
            id: id.uuidString,
            accountId: model.accountId.uuidString,
            amount: model.amount,
            currency: model.currency,
            date: formatter.string(from: model.occurredOn),
            merchant: model.merchant,
            descriptionText: model.descriptionText,
            pending: model.pending,
            status: BankTransactionStatus(rawValue: model.status) ?? .suggested,
            providerCategory: model.providerCategory,
            expenseId: model.expenseId?.uuidString,
            possibleDuplicate: possibleDuplicate
        )
    }
}

enum BankMappingError: Error {
    case missingID
}
