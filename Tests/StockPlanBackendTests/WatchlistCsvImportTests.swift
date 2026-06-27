import Fluent
import Foundation
import NIOCore
@testable import StockPlanBackend
import struct StockPlanShared.CsvImportPreviewError
import struct StockPlanShared.WatchlistCsvImportCommitResponse
import struct StockPlanShared.WatchlistCsvImportPreviewResponse
import struct StockPlanShared.WatchlistItemResponse
import struct StockPlanShared.WatchlistListRequest
import struct StockPlanShared.WatchlistListResponse
import Testing
import VaporTesting

@Suite("Watchlist CSV Import Integration Tests", .serialized)
struct WatchlistCsvImportTests {
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

    private func registerUser(on app: Application, identifier: String) async throws -> (token: String, userId: UUID) {
        let suffix = String(identifier.filter { $0.isLetter || $0.isNumber || $0 == "_" }.prefix(18))
        let request = AuthRegisterRequest(
            username: "watchcsv_\(suffix)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "watchcsv+\(identifier)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var response: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })
        guard let response else {
            throw Abort(.internalServerError, reason: "Missing auth response")
        }
        return (response.token, response.userId)
    }

    private func createWatchlistList(
        name: String,
        token: String,
        on app: Application
    ) async throws -> WatchlistListResponse {
        var created: WatchlistListResponse?
        try await app.testing().test(.POST, "v1/watchlist/lists", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(WatchlistListRequest(name: name))
        }, afterResponse: { res async throws in
            #expect(res.status == .created)
            created = try res.content.decode(WatchlistListResponse.self)
        })
        return try #require(created)
    }

    private func previewWatchlistCsv(
        token: String,
        csv: String,
        watchlistListId: String? = nil,
        on app: Application
    ) async throws -> (HTTPStatus, WatchlistCsvImportPreviewResponse?) {
        var path = "v1/watchlist/import/csv/preview"
        if let watchlistListId {
            path += "?watchlistListId=\(watchlistListId)"
        }
        var status: HTTPStatus = .internalServerError
        var response: WatchlistCsvImportPreviewResponse?
        try await app.testing().test(.POST, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            req.headers.replaceOrAdd(name: .contentType, value: "text/csv")
            req.body = ByteBufferAllocator().buffer(string: csv)
        }, afterResponse: { res async throws in
            status = res.status
            if res.status == .ok {
                response = try res.content.decode(WatchlistCsvImportPreviewResponse.self)
            }
        })
        return (status, response)
    }

    private func commitWatchlistCsv(
        token: String,
        csv: String,
        watchlistListId: String? = nil,
        on app: Application
    ) async throws -> (HTTPStatus, WatchlistCsvImportCommitResponse?) {
        var path = "v1/watchlist/import/csv/commit"
        if let watchlistListId {
            path += "?watchlistListId=\(watchlistListId)"
        }
        var status: HTTPStatus = .internalServerError
        var response: WatchlistCsvImportCommitResponse?
        try await app.testing().test(.POST, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            req.headers.replaceOrAdd(name: .contentType, value: "text/csv")
            req.body = ByteBufferAllocator().buffer(string: csv)
        }, afterResponse: { res async throws in
            status = res.status
            if res.status == .ok {
                response = try res.content.decode(WatchlistCsvImportCommitResponse.self)
            }
        })
        return (status, response)
    }

    private func listWatchlistItems(
        token: String,
        watchlistListId: String,
        on app: Application
    ) async throws -> [WatchlistItemResponse] {
        var items: [WatchlistItemResponse] = []
        try await app.testing().test(
            .GET,
            "v1/watchlist?watchlistListId=\(watchlistListId)",
            beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            },
            afterResponse: { res async throws in
                #expect(res.status == .ok)
                items = try res.content.decode([WatchlistItemResponse].self)
            }
        )
        return items
    }

    @Test("Preview parses symbol and notes with header aliases")
    func previewParsesSymbolAndNotes() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "preview-basic")

            let csv = """
            ticker,memo
            aapl,AI infrastructure
            MSFT,Cloud platform
            ,Missing symbol
            """

            let (status, preview) = try await previewWatchlistCsv(
                token: auth.token,
                csv: csv,
                on: app
            )

            #expect(status == .ok)
            #expect(preview?.items.count == 2)
            #expect(preview?.items.map(\.symbol) == ["AAPL", "MSFT"])
            #expect(preview?.items.first?.note == "AI infrastructure")
            #expect(preview?.errors.count == 1)
            #expect(preview?.errors.first?.line == 4)
            #expect(preview?.errors.first?.message == "Missing symbol.")
            #expect(preview?.watchlistListId.isEmpty == false)
        }
    }

    @Test("Commit inserts watchlist items into the target list")
    func commitInsertsItems() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "commit-insert")
            let techList = try await createWatchlistList(name: "Tech", token: auth.token, on: app)

            let csv = """
            symbol,notes
            AAPL,AI infrastructure
            MSFT,Cloud platform
            """

            let (status, commit) = try await commitWatchlistCsv(
                token: auth.token,
                csv: csv,
                watchlistListId: techList.id,
                on: app
            )

            #expect(status == .ok)
            #expect(commit?.errors.isEmpty == true)
            #expect(commit?.inserted.count == 2)
            #expect(commit?.updated.isEmpty == true)
            #expect(commit?.watchlistListId == techList.id)

            let items = try await listWatchlistItems(
                token: auth.token,
                watchlistListId: techList.id,
                on: app
            )
            #expect(items.count == 2)
            #expect(items.contains(where: { $0.symbol == "AAPL" && $0.note == "AI infrastructure" }))
            #expect(items.contains(where: { $0.symbol == "MSFT" && $0.note == "Cloud platform" }))
        }
    }

    @Test("Commit updates existing symbol notes in the same list")
    func commitUpdatesExistingSymbolNote() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "commit-update")
            let techList = try await createWatchlistList(name: "Tech", token: auth.token, on: app)

            let initialCSV = """
            symbol,notes
            AAPL,Old thesis
            """

            let firstCommit = try await commitWatchlistCsv(
                token: auth.token,
                csv: initialCSV,
                watchlistListId: techList.id,
                on: app
            )
            #expect(firstCommit.0 == .ok)
            #expect(firstCommit.1?.inserted.count == 1)

            let replacementCSV = """
            symbol,notes
            AAPL,Updated thesis
            """

            let (status, commit) = try await commitWatchlistCsv(
                token: auth.token,
                csv: replacementCSV,
                watchlistListId: techList.id,
                on: app
            )

            #expect(status == .ok)
            #expect(commit?.inserted.isEmpty == true)
            #expect(commit?.updated.count == 1)
            #expect(commit?.updated.first?.symbol == "AAPL")
            #expect(commit?.updated.first?.note == "Updated thesis")

            let items = try await listWatchlistItems(
                token: auth.token,
                watchlistListId: techList.id,
                on: app
            )
            #expect(items.count == 1)
            #expect(items.first?.note == "Updated thesis")
        }
    }

    @Test("Imports are scoped to the requested watchlist list")
    func importScopesToTargetList() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "scope-list")

            var defaultListId: String?
            try await app.testing().test(.GET, "v1/watchlist/lists", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let lists = try res.content.decode([WatchlistListResponse].self)
                defaultListId = lists.first(where: { $0.isDefault })?.id ?? lists.first?.id
            })
            let defaultListId = try #require(defaultListId)

            let techList = try await createWatchlistList(name: "Energy", token: auth.token, on: app)

            let csv = """
            symbol,notes
            XOM,Integrated major
            """

            let (status, _) = try await commitWatchlistCsv(
                token: auth.token,
                csv: csv,
                watchlistListId: techList.id,
                on: app
            )
            #expect(status == .ok)

            let techItems = try await listWatchlistItems(
                token: auth.token,
                watchlistListId: techList.id,
                on: app
            )
            #expect(techItems.count == 1)
            #expect(techItems.first?.symbol == "XOM")

            let defaultItems = try await listWatchlistItems(
                token: auth.token,
                watchlistListId: defaultListId,
                on: app
            )
            #expect(defaultItems.isEmpty)
        }
    }

    @Test("Duplicate symbols in CSV keep the last row")
    func duplicateSymbolsKeepLastRow() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "duplicate-rows")
            let list = try await createWatchlistList(name: "Large Caps", token: auth.token, on: app)

            let csv = """
            symbol,notes
            AAPL,First note
            AAPL,Final note
            """

            let preview = try await previewWatchlistCsv(
                token: auth.token,
                csv: csv,
                watchlistListId: list.id,
                on: app
            )
            #expect(preview.0 == .ok)
            #expect(preview.1?.items.count == 2)
            #expect(preview.1?.items.last?.willUpdateExisting == false)

            let commit = try await commitWatchlistCsv(
                token: auth.token,
                csv: csv,
                watchlistListId: list.id,
                on: app
            )
            #expect(commit.0 == .ok)
            #expect(commit.1?.inserted.count == 1)

            let items = try await listWatchlistItems(
                token: auth.token,
                watchlistListId: list.id,
                on: app
            )
            #expect(items.count == 1)
            #expect(items.first?.note == "Final note")
        }
    }

    @Test("Empty CSV body is rejected")
    func emptyBodyRejected() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "empty-body")

            let (status, _) = try await previewWatchlistCsv(
                token: auth.token,
                csv: "   \n",
                on: app
            )
            #expect(status == .badRequest)
        }
    }

    @Test("Watchlist CSV import requires authentication")
    func requiresAuthentication() async throws {
        try await withApp { app in
            let csv = """
            symbol,notes
            AAPL,Test
            """

            var status: HTTPStatus = .ok
            try await app.testing().test(.POST, "v1/watchlist/import/csv/preview", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .contentType, value: "text/csv")
                req.body = ByteBufferAllocator().buffer(string: csv)
            }, afterResponse: { res async throws in
                status = res.status
            })
            #expect(status == .unauthorized)
        }
    }
}
