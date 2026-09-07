import Foundation
import StockPlanShared
import Vapor

extension ActionCatalog {
    static var watchlistActions: [ActionDefinition] {
        [
            ActionDefinition(
                "list_watchlist",
                "List the user's watchlist entries with their status and notes."
            ) { context, _, req in
                let items = try await WatchlistService(req: req).list(userId: context.userId, on: req.db)
                return try encode(items.map(WatchlistService.response(from:)))
            },

            ActionDefinition(
                "upsert_watchlist_item",
                "Add a symbol to the watchlist, or update it if already present. Use status to record where it sits in your process.",
                properties: [
                    "symbol": OpenAIParameter(type: "string", description: "Ticker, for example AVGO."),
                    "status": OpenAIParameter(
                        type: "string",
                        description: "active, researching, waiting, ready, or archived",
                        enumValues: WatchlistStatus.allCases.map(\.rawValue)
                    ),
                    "note": OpenAIParameter(type: "string", description: "Free text, for example a buy zone."),
                ],
                required: ["symbol"]
            ) { context, args, req in
                guard let symbol = args.string("symbol") else {
                    return errorPayload("symbol is required")
                }
                var status: WatchlistStatus?
                if let raw = args.string("status") {
                    guard let parsed = WatchlistStatus(rawValue: raw) else {
                        let allowed = WatchlistStatus.allCases.map(\.rawValue).joined(separator: ", ")
                        return errorPayload("invalid status '\(raw)'; expected one of: \(allowed)")
                    }
                    status = parsed
                }
                let result = try await WatchlistService(req: req).upsert(
                    payload: WatchlistItemRequest(symbol: symbol, note: args.string("note"), status: status),
                    userId: context.userId,
                    on: req.db
                )
                return try encode(WatchlistService.response(from: result.item))
            },

            ActionDefinition(
                "remove_watchlist_item",
                "Permanently remove a watchlist entry.",
                properties: ["id": OpenAIParameter(type: "string", description: "Watchlist entry id.")],
                required: ["id"],
                destructive: true
            ) { context, args, req in
                guard let id = args.uuid("id") else { return errorPayload("invalid id") }
                try await WatchlistService(req: req).delete(id: id, userId: context.userId, on: req.db)
                return statusPayload("removed")
            },
        ]
    }

    static var positionActions: [ActionDefinition] {
        [
            ActionDefinition(
                "add_position",
                "Record a holding the user already owns. This is record-keeping and does not place a buy order.",
                properties: [
                    "symbol": OpenAIParameter(type: "string"),
                    "shares": OpenAIParameter(type: "number", description: "Shares, greater than 0."),
                    "buy_price": OpenAIParameter(type: "number", description: "Price per share paid."),
                    "buy_date": OpenAIParameter(type: "string", description: "YYYY-MM-DD"),
                    "category": OpenAIParameter(
                        type: "string",
                        description: "Asset category; defaults to stock.",
                        enumValues: AssetCategory.allCases.map(\.rawValue)
                    ),
                    "notes": OpenAIParameter(type: "string"),
                ],
                required: ["symbol", "shares", "buy_price", "buy_date"]
            ) { context, args, req in
                guard let symbol = args.string("symbol"), let shares = args.double("shares"),
                      let buyPrice = args.double("buy_price"), let buyDate = args.string("buy_date")
                else {
                    return errorPayload("missing required fields")
                }
                let category = args.string("category").flatMap(AssetCategory.init(rawValue:)) ?? .stock
                let created = try await req.stocksService.create(
                    payload: StockRequest(
                        symbol: symbol,
                        shares: shares,
                        buyPrice: buyPrice,
                        buyDate: buyDate,
                        notes: args.string("notes"),
                        category: category,
                        portfolioListId: args.string("portfolio_list_id")
                    ),
                    userId: context.userId,
                    on: req.db
                )
                return try encode(created)
            },

            ActionDefinition(
                "sell_position",
                """
                Record a sale against an existing position. Reduces the position, credits cash, \
                and records the trade so it reaches profit/loss and tax reports. Selling the whole \
                position removes its record. This is record-keeping and does not place a sell order.
                """,
                properties: [
                    "id": OpenAIParameter(type: "string", description: "Position id to sell from."),
                    "shares_to_sell": OpenAIParameter(type: "number"),
                    "sell_price": OpenAIParameter(type: "number", description: "Price per share received."),
                    "sell_date": OpenAIParameter(type: "string", description: "YYYY-MM-DD"),
                ],
                required: ["id", "shares_to_sell", "sell_price", "sell_date"],
                destructive: true
            ) { context, args, req in
                guard let id = args.uuid("id"), let shares = args.double("shares_to_sell"),
                      let price = args.double("sell_price"), let date = args.string("sell_date")
                else {
                    return errorPayload("missing required fields")
                }
                let sold = try await req.stocksService.sell(
                    id: id,
                    payload: SellStockRequest(sharesToSell: shares, sellPrice: price, sellDate: date),
                    userId: context.userId,
                    on: req.db
                )
                return try encode(sold)
            },

            ActionDefinition(
                "delete_position",
                "Permanently delete a position record. Use sell_position for an actual disposal; this erases the record as if it never existed.",
                properties: ["id": OpenAIParameter(type: "string")],
                required: ["id"],
                destructive: true
            ) { context, args, req in
                guard let id = args.uuid("id") else { return errorPayload("invalid id") }
                try await req.stocksService.delete(id: id, userId: context.userId, on: req.db)
                return statusPayload("deleted")
            },
        ]
    }
}
