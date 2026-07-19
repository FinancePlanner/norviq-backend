import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("GoCardless Provider", .serialized)
struct GoCardlessProviderTests {
    @Test("Booked transaction updates the pending suggestion when GoCardless changes ids")
    func bookedTransactionUpdatesPendingSuggestionWhenProviderIdChanges() async throws {
        try await withApp { app in
            let user = User(email: "gocardless-dedupe@example.com", passwordHash: "hash")
            try await user.save(on: app.db)
            let userId = try #require(user.id)

            let connection = BankConnection(
                userId: userId,
                provider: BankProviderKind.gocardless.rawValue,
                institutionId: "BANK_PT",
                institutionName: "Test Bank",
                providerItemId: "requisition-1",
                status: BankConnectionStatus.active.rawValue
            )
            try await connection.save(on: app.db)
            let connectionId = try #require(connection.id)

            let account = BankAccount(
                connectionId: connectionId,
                providerAccountId: "account-1",
                name: "Checking",
                currency: "EUR"
            )
            try await account.save(on: app.db)

            let provider = GoCardlessProvider(
                client: GoCardlessClient(
                    config: GoCardlessConfiguration(
                        secretID: "test-secret-id",
                        secretKey: "test-secret-key",
                        baseURL: "https://example.invalid"
                    )
                )
            )

            let pending = GCTransaction(
                transactionId: nil,
                internalTransactionId: "internal-pending-1",
                bookingDate: nil,
                valueDate: "2026-07-18",
                transactionAmount: GCTransactionAmount(amount: "-12.34", currency: "EUR"),
                remittanceInformationUnstructured: "Cafe Lisboa",
                creditorName: "Cafe Lisboa",
                debtorName: nil
            )
            let insertedPending = try await provider.upsert(pending, pending: true, account: account, userId: userId, on: app.db)
            #expect(insertedPending)

            let booked = GCTransaction(
                transactionId: "booked-transaction-1",
                internalTransactionId: "internal-pending-1",
                bookingDate: "2026-07-18",
                valueDate: nil,
                transactionAmount: GCTransactionAmount(amount: "-12.34", currency: "EUR"),
                remittanceInformationUnstructured: "Cafe Lisboa",
                creditorName: "Cafe Lisboa",
                debtorName: nil
            )
            let insertedBooked = try await provider.upsert(booked, pending: false, account: account, userId: userId, on: app.db)
            #expect(!insertedBooked)

            let transactions = try await BankTransaction.query(on: app.db).all()
            #expect(transactions.count == 1)

            let transaction = try #require(transactions.first)
            #expect(transaction.providerTxId == "booked-transaction-1")
            #expect(transaction.pending == false)
            #expect(transaction.status == BankTransactionStatus.suggested.rawValue)
        }
    }

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }
}
