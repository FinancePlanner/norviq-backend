import Foundation
import StockPlanShared
import Vapor

extension ActionCatalog {
    /// Trade record-keeping. These record trades already executed at a broker —
    /// nothing here places an order, and the broker integration is read-only by
    /// construction, so the wording matters: an assistant reading "sell" must not
    /// imply it can instruct the broker.
    static var transactionActions: [ActionDefinition] {
        [
            ActionDefinition(
                "list_transactions",
                "List the user's recorded trades, both hand-entered and broker-imported."
            ) { context, _, req in
                let rows = try await TransactionService(req: req).list(userId: context.userId, on: req.db)
                return try encode(rows)
            },

            ActionDefinition(
                "record_trade",
                "Record a trade the user already executed at their broker. This is record-keeping and does not place an order.",
                properties: [
                    "symbol": OpenAIParameter(type: "string", description: "Ticker, for example AVGO."),
                    "type": OpenAIParameter(type: "string", description: "buy or sell", enumValues: ["buy", "sell"]),
                    "quantity": OpenAIParameter(type: "number", description: "Shares, greater than 0."),
                    "price": OpenAIParameter(type: "number", description: "Price per share, greater than 0."),
                    "trade_date": OpenAIParameter(type: "string", description: "YYYY-MM-DD"),
                    "currency": OpenAIParameter(type: "string", description: "ISO currency code, optional."),
                    "fees": OpenAIParameter(type: "number", description: "Commission and fees, optional."),
                ],
                required: ["symbol", "type", "quantity", "price", "trade_date"]
            ) { context, args, req in
                guard let symbol = args.string("symbol"), let type = args.string("type"),
                      let quantity = args.double("quantity"), let price = args.double("price"),
                      let tradeDate = args.string("trade_date")
                else {
                    return errorPayload("missing required fields")
                }
                let payload = CreateTransactionRequest(
                    symbol: symbol,
                    type: type,
                    quantity: quantity,
                    price: price,
                    currency: args.string("currency"),
                    tradeDate: tradeDate,
                    settleDate: args.string("settle_date"),
                    fees: args.double("fees"),
                    portfolioListId: args.string("portfolio_list_id")
                )
                let created = try await TransactionService(req: req).create(
                    payload: payload, userId: context.userId, on: req.db
                )
                return try encode(created)
            },

            ActionDefinition(
                "delete_trade",
                "Permanently delete a hand-entered trade record. This affects realized profit/loss and tax reports.",
                properties: ["id": OpenAIParameter(type: "string")],
                required: ["id"],
                destructive: true
            ) { context, args, req in
                guard let id = args.uuid("id") else { return errorPayload("invalid id") }
                try await TransactionService(req: req).delete(id: id, userId: context.userId, on: req.db)
                return statusPayload("deleted")
            },
        ]
    }
}
