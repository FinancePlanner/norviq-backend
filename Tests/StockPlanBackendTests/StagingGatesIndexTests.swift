import Fluent
import FluentSQL
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// M8: follow lookups by target list are indexed.
extension StagingGatesTests {
    @Test("pilot_follows is indexed on portfolio_list_id and watchlist_list_id")
    func pilotFollowTargetsAreIndexed() async throws {
        try await withApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            struct Row: Decodable { let indexdef: String }
            let defs = try await sql.raw("""
            SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND tablename = 'pilot_follows'
            """).all(decoding: Row.self).map(\.indexdef)
            #expect(defs.contains { $0.hasSuffix("(portfolio_list_id)") }, "\(defs)")
            #expect(defs.contains { $0.hasSuffix("(watchlist_list_id)") }, "\(defs)")
        }
    }
}
