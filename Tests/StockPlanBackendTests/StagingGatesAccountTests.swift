import Fluent
import Foundation
import NIOCore
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

/// G4: the pilot account cannot be moved, and "pilot" is not a broker name a
/// client may use.
extension StagingGatesTests {
    @Test("the pilot account cannot be reassigned; a manual account still can")
    func pilotAccountCannotBeReassigned() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            try await grantPro(userId, on: app)
            let seeded = try await seedFollowedList(userId: userId, on: app.db)
            let actual = PortfolioList(userId: userId, name: "Real", isDefault: true)
            try await actual.create(on: app.db)
            let actualId = try actual.requireID()
            let pilotAccountId = try seeded.pilotAccount.requireID()

            try await app.testing().test(.PUT, "v1/portfolios/\(actualId)/accounts/\(pilotAccountId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }) { res async throws in
                #expect(res.status == .unprocessableEntity, "\(res.status) \(res.body.string)")
                #expect(res.body.string.contains("Simulated accounts can't be reassigned."), "\(res.body.string)")
            }
            #expect(try await Account.find(pilotAccountId, on: app.db)?.portfolioId == seeded.listId)

            let manual = Account(userId: userId, externalId: "gate-manual-\(UUID().uuidString)", broker: "manual", displayName: "Manual", baseCurrency: "USD")
            try await manual.create(on: app.db)
            try await app.testing().test(.PUT, "v1/portfolios/\(actualId)/accounts/\(manual.requireID())", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }) { res async throws in
                #expect(res.status == .noContent, "\(res.status) \(res.body.string)")
            }
            #expect(try await Account.find(manual.requireID(), on: app.db)?.portfolioId == actualId)
        }
    }

    @Test("\"pilot\" is a reserved broker provider in any spelling; neighbours are not")
    func pilotProviderIsReserved() throws {
        for raw in ["pilot", "Pilot", " PILOT ", "pilot\n"] {
            do {
                let normalized = try BrokerProvider.normalize(raw)
                Issue.record("\(raw.debugDescription) normalized to \(normalized)")
            } catch let error as any AbortError {
                #expect(error.status == .badRequest)
                #expect(error.reason == "\"pilot\" is reserved.")
            }
        }
        #expect(try BrokerProvider.normalize("pilots") == "pilots")
        #expect(try BrokerProvider.normalize("Pilot Fund") == "pilot-fund")
        #expect(try BrokerProvider.normalize("IBKR") == "ibkr")
    }

    @Test("a CSV import named \"pilot\" is 400 and creates no pilot-broker account")
    func csvImportWithPilotProviderIsRejected() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            try await grantPro(userId, on: app)
            _ = try await seedInstrument(symbol: "AMD", on: app.db)
            let csv = """
            symbol,shares,buy_price,buy_date
            AMD,9,120.25,2026-02-03
            """
            for path in ["v1/brokers/import/csv?provider=pilot", "v1/brokers/import/csv/commit?provider=Pilot"] {
                try await app.testing().test(.POST, path, beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                    req.headers.replaceOrAdd(name: .contentType, value: "text/csv")
                    req.body = ByteBufferAllocator().buffer(string: csv)
                }) { res async throws in
                    #expect(res.status == .badRequest, "\(path): \(res.status) \(res.body.string)")
                    #expect(res.body.string.contains("is reserved"), "\(path): \(res.body.string)")
                }
            }
            #expect(try await Account.query(on: app.db).filter(\.$userId == userId).count() == 0)
            #expect(try await Stock.query(on: app.db).filter(\.$userId == userId).count() == 0)
        }
    }
}
