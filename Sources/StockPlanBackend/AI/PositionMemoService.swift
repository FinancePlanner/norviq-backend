import Fluent
import Foundation
import StockPlanShared
import Vapor

enum PositionMemoService {
    static func generate(
        ask: PositionMemoAsk,
        userId: UUID,
        conversationId: UUID,
        client: any OpenAIChatClient,
        on req: Request
    ) async throws -> PositionMemoCard {
        let started = Date()
        let built = await PositionMemoEvidence.build(ask: ask, userId: userId, on: req)
        let messages = try PositionMemoWriter.messages(pack: built.pack, mark: built.mark)
        let reply = try await client.chat(messages: messages, tools: [], responseFormat: "json_object", on: req)
        let draft = try PositionMemoDraftGuard.apply(PositionMemoWriter.parse(reply.content), pack: built.pack)
        let sources = PositionMemoSources.build(pack: built.pack, mark: built.mark)
        let row = try PositionMemo(
            userId: userId,
            conversationId: conversationId,
            askedSymbol: built.pack.askedSymbol,
            primarySymbol: built.pack.primarySymbol,
            titleEncrypted: seal(draft.title, on: req),
            markEncrypted: seal(built.mark, on: req),
            sectionsEncrypted: seal(draft.sections, on: req),
            verdictEncrypted: seal(draft.verdict, on: req),
            sourcesEncrypted: seal(sources, on: req),
            evidenceEncrypted: seal(built.pack, on: req)
        )
        try await row.create(on: req.db)
        let id = try row.requireID()
        req.logger.notice("position_memo.wrote symbol=\(built.pack.primarySymbol) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        return PositionMemoCard(
            id: id.uuidString,
            symbol: built.pack.primarySymbol,
            title: draft.title,
            verdict: draft.verdict,
            bookmarked: false
        )
    }

    static func list(userId: UUID, bookmarked: Bool?, conversationId: UUID?, on req: Request) async throws -> [PositionMemoListItem] {
        var query = PositionMemo.query(on: req.db)
            .filter(\.$userId == userId)
            .sort(\.$createdAt, .descending)
            .limit(50)
        if let bookmarked {
            query = query.filter(\.$bookmarked == bookmarked)
        }
        if let conversationId {
            query = query.filter(\.$conversationId == conversationId)
        }
        let rows = try await query.all()
        return try rows.map { try listItem($0, on: req) }
    }

    static func detail(id: UUID, userId: UUID, on req: Request) async throws -> PositionMemoDetail {
        let row = try await owned(id: id, userId: userId, on: req)
        return try detail(row, on: req)
    }

    static func setBookmarked(id: UUID, userId: UUID, bookmarked: Bool, on req: Request) async throws -> PositionMemoCard {
        let row = try await owned(id: id, userId: userId, on: req)
        row.bookmarked = bookmarked
        try await row.save(on: req.db)
        return try card(row, on: req)
    }

    static func delete(id: UUID, userId: UUID, on req: Request) async throws {
        try await owned(id: id, userId: userId, on: req).delete(on: req.db)
    }

    static func owned(id: UUID, userId: UUID, on req: Request) async throws -> PositionMemo {
        guard let row = try await PositionMemo.query(on: req.db)
            .filter(\.$id == id)
            .filter(\.$userId == userId)
            .first()
        else { throw Abort(.notFound) }
        return row
    }

    static func card(_ row: PositionMemo, on req: Request) throws -> PositionMemoCard {
        try PositionMemoCard(
            id: row.requireID().uuidString,
            symbol: row.primarySymbol,
            title: open(row.titleEncrypted, as: String.self, on: req),
            verdict: open(row.verdictEncrypted, as: String.self, on: req),
            bookmarked: row.bookmarked
        )
    }

    private static func listItem(_ row: PositionMemo, on req: Request) throws -> PositionMemoListItem {
        try PositionMemoListItem(
            id: row.requireID().uuidString,
            askedSymbol: row.askedSymbol,
            primarySymbol: row.primarySymbol,
            title: open(row.titleEncrypted, as: String.self, on: req),
            verdict: open(row.verdictEncrypted, as: String.self, on: req),
            bookmarked: row.bookmarked,
            createdAt: timestamp(row.createdAt)
        )
    }

    private static func detail(_ row: PositionMemo, on req: Request) throws -> PositionMemoDetail {
        try PositionMemoDetail(
            id: row.requireID().uuidString,
            askedSymbol: row.askedSymbol,
            primarySymbol: row.primarySymbol,
            title: open(row.titleEncrypted, as: String.self, on: req),
            mark: open(row.markEncrypted, as: PositionMemoMark.self, on: req),
            sections: open(row.sectionsEncrypted, as: [PositionMemoSection].self, on: req),
            verdict: open(row.verdictEncrypted, as: String.self, on: req),
            sources: open(row.sourcesEncrypted, as: [PositionMemoSource].self, on: req),
            footer: PositionMemoCopy.footer,
            bookmarked: row.bookmarked,
            createdAt: timestamp(row.createdAt)
        )
    }

    private static func seal(_ value: some Encodable, on req: Request) throws -> Data {
        let data = try JSONEncoder().encode(value)
        let text = String(decoding: data, as: UTF8.self)
        return try req.userPIIEncryptionService.encryptString(text)
    }

    private static func open<T: Decodable>(_ payload: Data, as type: T.Type, on req: Request) throws -> T {
        let text = try req.userPIIEncryptionService.decryptString(payload)
        guard let data = text.data(using: .utf8) else { throw Abort(.internalServerError) }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func timestamp(_ date: Date?) -> String {
        ISO8601DateFormatter().string(from: date ?? Date())
    }
}
