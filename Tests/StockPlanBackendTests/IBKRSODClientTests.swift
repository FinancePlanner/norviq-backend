import Foundation
@testable import StockPlanBackend
import Testing
import Vapor

struct IBKRSODClientTests {
    @Test("Builds SOD URL with token query date and service code")
    func buildsRequestURL() throws {
        let client = IBKRSODClient(
            configuration: IBKRSODConfiguration(
                baseURL: IBKRSODConfiguration.defaultBaseURL,
                serviceCode: IBKRSODConfiguration.defaultServiceCode
            )
        )
        let uri = try client.makeRequestURL(token: "tok", queryId: "qid", reportDate: "20240511")
        let components = try #require(URLComponents(string: uri.string))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        #expect(components.host == "ndcdyn.interactivebrokers.com")
        #expect(components.path == "/Reporting/IBRITService")
        #expect(query["t"] == "tok")
        #expect(query["q"] == "qid")
        #expect(query["rd"] == "20240511")
        #expect(query["s"] == "norviq -ws")
    }

    @Test("Parses documented SOD error codes from short bodies")
    func parsesErrorCodes() {
        #expect(IBKRSODClient.parseErrorCode(from: "1052") == .invalidTokenOrQuery)
        #expect(IBKRSODClient.parseErrorCode(from: "Error 1019 Statement generation in progress") == .generationInProgress)
        #expect(IBKRSODClient.parseErrorCode(from: "1010") == .noStatement)
        #expect(IBKRSODClient.parseErrorCode(from: "1018") == .rateLimited)
        // Large CSV with incidental numbers should not false-positive.
        let csv = String(repeating: "DATA,AAPL,10,1052\n", count: 40)
        #expect(IBKRSODClient.parseErrorCode(from: csv) == nil)
    }

    @Test("Previous business day skips weekends")
    func previousBusinessDaySkipsWeekends() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        // Monday 2024-05-13 → Friday 2024-05-10
        let monday = try #require(calendar.date(from: DateComponents(year: 2024, month: 5, day: 13)))
        let previous = IBKRSODReportDate.previousBusinessDay(from: monday)
        #expect(IBKRSODReportDate.format(previous) == "20240510")
    }

    @Test("Fetch maps 1052 to invalid token error")
    func fetchMapsInvalidToken() async throws {
        let transport = MockSODTransport(responses: [
            (.ok, ByteBuffer(string: "1052 Token or query ID is invalid")),
        ])
        let client = IBKRSODClient(
            configuration: .fromEnvironment(),
            transport: transport,
            rateLimiter: IBKRSODRateLimiter()
        )
        let app = try await Application.make(.testing)
        let req = Request(application: app, on: app.eventLoopGroup.next())

        do {
            _ = try await client.fetch(token: "t", queryId: "q", reportDate: "20240511", on: req)
            Issue.record("Expected error")
        } catch let error as IBKRSODError {
            guard case let .service(code, _) = error else {
                Issue.record("Unexpected error \(error)")
                try await app.asyncShutdown()
                return
            }
            #expect(code == .invalidTokenOrQuery)
        }
        try await app.asyncShutdown()
    }

    @Test("Fetch retries 1019 then succeeds")
    func fetchRetriesGenerationInProgress() async throws {
        let transport = MockSODTransport(responses: [
            (.ok, ByteBuffer(string: "1019")),
            (.ok, ByteBuffer(string: "Open Positions,Header,Symbol,Quantity\nOpen Positions,Data,AAPL,1\n")),
        ])
        let client = IBKRSODClient(transport: transport, rateLimiter: IBKRSODRateLimiter())
        let app = try await Application.make(.testing)
        let req = Request(application: app, on: app.eventLoopGroup.next())

        let result = try await client.fetch(
            token: "t",
            queryId: "q",
            reportDate: "20240511",
            on: req,
            maxGenerationRetries: 3
        )
        #expect(result.files.count == 1)
        #expect(result.files[0].csvText.contains("AAPL"))
        #expect(transport.calls == 2)
        try await app.asyncShutdown()
    }
}

struct IBKRSODHTCSVParserTests {
    @Test("Parses flex-style Header/Data sections")
    func parsesFlexStyleFixture() throws {
        let csv = try loadFixture("flex-style-sample.csv")
        let document = try IBKRSODHTCSVParser().parse(csv)
        #expect(document.sections.count == 2)
        #expect(document.sections[0].name == "Open Positions")
        #expect(document.sections[0].rows.count == 2)
        #expect(document.sections[0].rows[0]["symbol"] == "AAPL")
        #expect(document.sections[1].name == "Trades")
        #expect(document.sections[1].rows.count == 2)
    }

    @Test("Parses H/T discriminator fixture")
    func parsesHTDiscriminatorFixture() throws {
        let csv = try loadFixture("ht-discriminator-sample.csv")
        let document = try IBKRSODHTCSVParser().parse(csv)
        #expect(document.sections.contains(where: { $0.name == "Open Positions" && $0.rows.count == 2 }))
        let positions = document.sections.first(where: { $0.name == "Open Positions" })
        #expect(positions?.rows[0]["symbol"] == "ASTS")
    }

    @Test("Statement parser extracts provisional positions and activities")
    func statementParserExtractsProvisionalRows() throws {
        let csv = try loadFixture("flex-style-sample.csv")
        let fetch = IBKRSODFetchResult(
            reportDate: "20240511",
            files: [IBKRSODFilePayload(name: "flex-style-sample.csv", csvText: csv)]
        )
        let parsed = try IBKRSODStatementParser().parse(fetch: fetch)
        #expect(parsed.provisionalPositions.count == 2)
        #expect(parsed.provisionalActivities.count == 2)
        #expect(parsed.provisionalPositions.map(\.symbol).sorted() == ["AAPL", "MSFT"])
    }

    private func loadFixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ibkr-sod/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private final class MockSODTransport: IBKRSODHTTPTransport, @unchecked Sendable {
    private var queue: [(HTTPResponseStatus, ByteBuffer)]
    private(set) var calls = 0

    init(responses: [(HTTPResponseStatus, ByteBuffer)]) {
        queue = responses
    }

    func get(uri _: URI, on _: Request) async throws -> (status: HTTPResponseStatus, body: ByteBuffer) {
        calls += 1
        guard !queue.isEmpty else {
            throw Abort(.badGateway, reason: "Mock SOD transport exhausted")
        }
        return queue.removeFirst()
    }
}
