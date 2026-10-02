import Fluent
import Foundation
@testable import StockPlanBackend
import Testing
import Vapor

@Suite("SECEdgar13FPilotSource", .serialized)
struct SECEdgar13FPilotSourceTests {
    private let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pilots/edgar")
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent(name))
    }

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withSharedAccess {
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

    @Test("finds the latest 13F-HR and its period")
    func latestFiling() throws {
        let ref = try #require(try EDGAR13FParser.latest13F(submissions: fixture("submissions.json")))
        #expect(ref.accession.count == 20)
        #expect(ref.period.range(of: #"^\d{4}Q[1-4]$"#, options: .regularExpression) != nil)
    }

    @Test("period from report date")
    func period() {
        #expect(EDGARFilingRef(accession: "x", reportDate: "2026-06-30").period == "2026Q2")
        #expect(EDGARFilingRef(accession: "x", reportDate: "2025-12-31").period == "2025Q4")
    }

    @Test("picks the information table, not primary_doc.xml")
    func infoTable() throws {
        let name = try #require(try EDGAR13FParser.infoTableName(index: fixture("index.json")))
        #expect(name.hasSuffix(".xml"))
        #expect(name != "primary_doc.xml")
    }

    @Test("parses the real info table: positive values, unique CUSIPs")
    func realHoldings() throws {
        let rows = try EDGAR13FParser.holdings(infoTable: fixture("infotable.xml"))
        #expect(rows.count >= 20)
        #expect(Set(rows.map(\.cusip)).count == rows.count)
        #expect(rows.allSatisfy { $0.value > 0 && $0.shares > 0 && $0.cusip.count == 9 })
    }

    @Test("skips options and principal-amount rows; sums split rows; strips namespace prefixes")
    func filtering() throws {
        let xml = """
        <?xml version="1.0"?>
        <ns1:informationTable xmlns:ns1="http://www.sec.gov/edgar/document/thirteenf/informationtable">
          <ns1:infoTable><ns1:cusip>037833100</ns1:cusip><ns1:value>600</ns1:value><ns1:shrsOrPrnAmt><ns1:sshPrnamt>3</ns1:sshPrnamt><ns1:sshPrnamtType>SH</ns1:sshPrnamtType></ns1:shrsOrPrnAmt></ns1:infoTable>
          <ns1:infoTable><ns1:cusip>037833100</ns1:cusip><ns1:value>400</ns1:value><ns1:shrsOrPrnAmt><ns1:sshPrnamt>2</ns1:sshPrnamt><ns1:sshPrnamtType>SH</ns1:sshPrnamtType></ns1:shrsOrPrnAmt></ns1:infoTable>
          <ns1:infoTable><ns1:cusip>78462F103</ns1:cusip><ns1:value>50</ns1:value><ns1:shrsOrPrnAmt><ns1:sshPrnamt>1</ns1:sshPrnamt><ns1:sshPrnamtType>SH</ns1:sshPrnamtType></ns1:shrsOrPrnAmt><ns1:putCall>Put</ns1:putCall></ns1:infoTable>
          <ns1:infoTable><ns1:cusip>912828ZZ1</ns1:cusip><ns1:value>70</ns1:value><ns1:shrsOrPrnAmt><ns1:sshPrnamt>70</ns1:sshPrnamt><ns1:sshPrnamtType>PRN</ns1:sshPrnamtType></ns1:shrsOrPrnAmt></ns1:infoTable>
        </ns1:informationTable>
        """
        let rows = try EDGAR13FParser.holdings(infoTable: Data(xml.utf8))
        #expect(rows == [EDGAR13FHolding(cusip: "037833100", value: 1000, shares: 5)])
    }

    @Test("source: maps holdings through the resolver; unresolved CUSIPs dropped")
    func source() async throws {
        let src = SECEdgar13FPilotSource(
            get: { url in
                if url.contains("submissions") {
                    return try fixture("submissions.json")
                }
                if url.hasSuffix("index.json") {
                    return try fixture("index.json")
                }
                return try fixture("infotable.xml")
            },
            resolve: { cusips in Dictionary(uniqueKeysWithValues: cusips.prefix(3).map { ($0, "T\($0.prefix(3))") }) }
        )
        let out = try await src.disclosures(for: PilotSourceIdentity(kind: .fund, chamber: nil, bioguideId: nil, aliases: [], cik: "0001067983"))
        #expect(out.count == 3)
        #expect(out.allSatisfy { $0.side == .hold && $0.instrument == .stock && $0.marketValue ?? 0 > 0 })
        #expect(out.allSatisfy { $0.sourceKey.hasPrefix(out[0].period! + "|") })
    }

    @Test("resolver: batches of 10, caches hits and misses, never asks twice")
    func resolver() async throws {
        try await withApp { app in
            let posts = PostLog()
            let figi = try fixture("openfigi.json")
            let resolver = CusipSymbolResolver(
                post: { body in
                    await posts.record(body)
                    return figi
                },
                pause: {}
            )
            let cusips = ["037833100", "191216100", "000000000"]
            let first = try await resolver.resolve(cusips, on: app.db)
            #expect(first == ["037833100": "AAPL", "191216100": "KO"])
            let second = try await resolver.resolve(cusips, on: app.db)
            #expect(second == first)
            #expect(await posts.count == 1)
        }
    }

    @Test("resolver: OpenFIGI class tickers use a dot (BRK/B -> BRK.B)")
    func classTickers() async throws {
        try await withApp { app in
            let response = Data(#"[{"data":[{"ticker":"BRK/B"}]},{"data":[{"ticker":"bf/a"}]}]"#.utf8)
            let resolver = CusipSymbolResolver(post: { _ in response }, pause: {})
            let cusips = ["084670702", "115637100"]
            let out = try await resolver.resolve(cusips, on: app.db)
            #expect(out == [cusips[0]: "BRK.B", cusips[1]: "BF.A"])
        }
    }
}

private actor PostLog {
    var count = 0
    func record(_: Data) {
        count += 1
    }
}
