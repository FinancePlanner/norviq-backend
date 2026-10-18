import Fluent
import Foundation
import SQLKit

protocol InsightsRepository: Sendable {
    func insertNewEvents(_ events: [InsightEvent], on db: any Database) async throws -> Int
    func insertNewTickerPosts(_ posts: [TickerSentimentPost], on db: any Database) async throws -> Int
    func insertNewNetWorthSnapshots(_ snapshots: [NetWorthSnapshot], on db: any Database) async throws -> Int
    func upsertSentimentSnapshot(_ snapshot: SentimentSnapshot, on db: any Database) async throws
    func recentEvents(topic: String?, since: Date, limit: Int, on db: any Database) async throws -> [InsightEvent]
    func topicCounts(since: Date, on db: any Database) async throws -> [String: Int]
    func latestSentimentSnapshot(scope: String, scopeKey: String?, on db: any Database) async throws -> SentimentSnapshot?
    func netWorthSnapshots(limit: Int, on db: any Database) async throws -> [NetWorthSnapshot]
    func tickerPosts(symbol: String, since: Date, limit: Int, on db: any Database) async throws -> [TickerSentimentPost]
    func allTrackedSymbols(limit: Int, on db: any Database) async throws -> [String]
    func topPositionSymbols(perUserLimit: Int, limit: Int, on db: any Database) async throws -> [String]
}

struct DatabaseInsightsRepository: InsightsRepository {
    func insertNewEvents(_ events: [InsightEvent], on db: any Database) async throws -> Int {
        guard !events.isEmpty else { return 0 }
        let keys = events.map(\.dedupeKey)
        let existing = try await InsightEvent.query(on: db)
            .filter(\.$dedupeKey ~~ keys)
            .all()
            .map(\.dedupeKey)
        let existingSet = Set(existing)
        var batchSeen = Set<String>()
        let fresh = events.filter {
            !existingSet.contains($0.dedupeKey) && batchSeen.insert($0.dedupeKey).inserted
        }
        for event in fresh {
            try await event.save(on: db)
        }
        return fresh.count
    }

    func insertNewTickerPosts(_ posts: [TickerSentimentPost], on db: any Database) async throws -> Int {
        guard !posts.isEmpty else { return 0 }
        let keys = posts.map(\.dedupeKey)
        let existing = try await TickerSentimentPost.query(on: db)
            .filter(\.$dedupeKey ~~ keys)
            .all()
            .map(\.dedupeKey)
        let existingSet = Set(existing)
        var batchSeen = Set<String>()
        let fresh = posts.filter {
            !existingSet.contains($0.dedupeKey) && batchSeen.insert($0.dedupeKey).inserted
        }
        for post in fresh {
            try await post.save(on: db)
        }
        return fresh.count
    }

    func insertNewNetWorthSnapshots(_ snapshots: [NetWorthSnapshot], on db: any Database) async throws -> Int {
        guard !snapshots.isEmpty else { return 0 }
        let keys = snapshots.map(\.dedupeKey)
        let existing = try await NetWorthSnapshot.query(on: db)
            .filter(\.$dedupeKey ~~ keys)
            .all()
            .map(\.dedupeKey)
        let existingSet = Set(existing)
        var batchSeen = Set<String>()
        let fresh = snapshots.filter {
            !existingSet.contains($0.dedupeKey) && batchSeen.insert($0.dedupeKey).inserted
        }
        for snapshot in fresh {
            try await snapshot.save(on: db)
        }
        return fresh.count
    }

    func upsertSentimentSnapshot(_ snapshot: SentimentSnapshot, on db: any Database) async throws {
        if let existing = try await SentimentSnapshot.query(on: db)
            .filter(\.$dedupeKey == snapshot.dedupeKey)
            .first()
        {
            existing.averageScore = snapshot.averageScore
            existing.label = snapshot.label
            existing.eventCount = snapshot.eventCount
            existing.positiveCount = snapshot.positiveCount
            existing.neutralCount = snapshot.neutralCount
            existing.negativeCount = snapshot.negativeCount
            existing.capturedAt = snapshot.capturedAt
            try await existing.save(on: db)
        } else {
            try await snapshot.save(on: db)
        }
    }

    func recentEvents(topic: String?, since: Date, limit: Int, on db: any Database) async throws -> [InsightEvent] {
        let query = InsightEvent.query(on: db)
            .filter(\.$observedAt >= since)
            .sort(\.$observedAt, .descending)
            .limit(limit)
        if let topic, !topic.isEmpty {
            query.filter(\.$topic == topic)
        }
        return try await query.all()
    }

    func topicCounts(since: Date, on db: any Database) async throws -> [String: Int] {
        let events = try await InsightEvent.query(on: db)
            .filter(\.$observedAt >= since)
            .field(\.$topic)
            .all()
        var counts: [String: Int] = [:]
        for event in events {
            counts[event.topic, default: 0] += 1
        }
        return counts
    }

    func latestSentimentSnapshot(scope: String, scopeKey: String?, on db: any Database) async throws -> SentimentSnapshot? {
        let query = SentimentSnapshot.query(on: db)
            .filter(\.$scope == scope)
            .sort(\.$capturedAt, .descending)
        if let scopeKey {
            query.filter(\.$scopeKey == scopeKey)
        }
        return try await query.first()
    }

    func netWorthSnapshots(limit: Int, on db: any Database) async throws -> [NetWorthSnapshot] {
        try await NetWorthSnapshot.query(on: db)
            .sort(\.$capturedAt, .descending)
            .limit(limit)
            .all()
    }

    func tickerPosts(symbol: String, since: Date, limit: Int, on db: any Database) async throws -> [TickerSentimentPost] {
        try await TickerSentimentPost.query(on: db)
            .filter(\.$symbol == symbol)
            .filter(\.$postedAt >= since)
            .sort(\.$postedAt, .descending)
            .limit(limit)
            .all()
    }

    func allTrackedSymbols(limit: Int, on db: any Database) async throws -> [String] {
        guard let sql = db as? any SQLDatabase else { return [] }
        // Raised from 200: the sentiment universe wants every symbol any user
        // holds or watches, not just the popular head. The Hermes machine
        // endpoint still passes its own much smaller HERMES_TRACKED_TICKERS_LIMIT.
        let cappedLimit = max(1, min(limit, 1000))
        // Union of equity holdings and non-archived watchlist symbols, ranked by
        // how many distinct users track each symbol. Symbols normalized upper/trim.
        let rows = try await sql.raw("""
            SELECT symbol, COUNT(DISTINCT user_id) AS holders
            FROM (
                SELECT UPPER(TRIM(symbol)) AS symbol, user_id FROM stocks WHERE category = 'stock'
                UNION
                SELECT UPPER(TRIM(symbol)) AS symbol, user_id FROM watchlist_items WHERE status <> 'archived'
            ) AS tracked
            WHERE symbol <> ''
            GROUP BY symbol
            ORDER BY holders DESC, symbol ASC
            LIMIT \(bind: cappedLimit)
        """).all()
        return try rows.map { try $0.decode(column: "symbol", as: String.self) }
    }

    func topPositionSymbols(perUserLimit: Int, limit: Int, on db: any Database) async throws -> [String] {
        guard let sql = db as? any SQLDatabase else { return [] }
        let cappedPerUser = max(1, min(perUserLimit, 100))
        let cappedLimit = max(1, min(limit, 1000))
        // Each user's largest equity positions by cost basis (shares × buy_price,
        // lots of the same symbol summed), then ranked across users by how many
        // hold it and by combined cost basis. Cost basis is in each position's
        // own currency and ignores price moves; it is a size proxy, not a value.
        // Watchlist items are left out: they have no size to rank by.
        let rows = try await sql.raw("""
            WITH positions AS (
                SELECT UPPER(TRIM(symbol)) AS symbol, user_id, SUM(shares * buy_price) AS cost_basis
                FROM stocks
                WHERE category = 'stock' AND TRIM(symbol) <> ''
                GROUP BY UPPER(TRIM(symbol)), user_id
            ), ranked AS (
                SELECT symbol, user_id, cost_basis,
                       ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY cost_basis DESC, symbol ASC) AS position_rank
                FROM positions
            )
            SELECT symbol, COUNT(*) AS holders, SUM(cost_basis) AS total_cost_basis
            FROM ranked
            WHERE position_rank <= \(bind: cappedPerUser)
            GROUP BY symbol
            ORDER BY holders DESC, total_cost_basis DESC, symbol ASC
            LIMIT \(bind: cappedLimit)
        """).all()
        return try rows.map { try $0.decode(column: "symbol", as: String.self) }
    }
}
