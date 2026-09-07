import Foundation

extension ActionCatalog {
    /// What the user reads before approving a destructive action.
    ///
    /// This is the *only* thing standing between a model's intent and a deletion:
    /// iOS renders it in the confirmation card, web renders it in the assistant
    /// pane, and Telegram sends it as the message body above the Confirm button.
    /// "Delete the selected expense." — the string this replaced — is not
    /// something a person can meaningfully consent to, so each summary names the
    /// arguments that identify the row.
    ///
    /// It can only describe what the model actually passed. For an id-only
    /// delete that is the id, because building the proposal happens before any
    /// lookup; enriching it would mean a database read on the proposing turn.
    ///
    /// The result is stored in `AIPendingAction.summaryEncrypted`, so PII here is
    /// already handled at rest.
    static func confirmationSummary(name: String, arguments: ActionArguments) -> String {
        summaryCopy(name: canonicalName(for: name), arguments: arguments)
            ?? "Apply this change to your Norviq data."
    }

    /// Past-tense confirmation once the action has run.
    static func completionMessage(name: String) -> String {
        completionCopy(name: canonicalName(for: name)) ?? "Done."
    }

    /// Whether both strings are authored for this action, rather than falling
    /// back to the generic wording. Adding an action without copy fails a test.
    static func hasCopy(for name: String) -> Bool {
        let canonical = canonicalName(for: name)
        return summaryCopy(name: canonical, arguments: ActionArguments([:])) != nil
            && completionCopy(name: canonical) != nil
    }

    // MARK: - Copy

    private static func summaryCopy(name: String, arguments args: ActionArguments) -> String? {
        switch name {
        case "list_watchlist":
            return "Read your watchlist."
        case "list_transactions":
            return "Read your recorded trades."
        case "list_goals":
            return "Read your financial goals."
        case "add_expense":
            return "Add the expense \(quoted(args.string("title")))\(amountClause(args))\(dateClause(args, "occurred_on"))."
        case "update_expense":
            return "Update expense \(shortId(args))."
        case "delete_expense":
            return "Permanently delete expense \(shortId(args)). This cannot be undone."
        case "upsert_watchlist_item":
            let status = args.string("status").map { ", status \($0)" } ?? ""
            return "Add \(symbol(args)) to your watchlist\(status)."
        case "remove_watchlist_item":
            return "Permanently remove watchlist entry \(shortId(args))."
        case "add_position":
            return "Record \(number(args.double("shares"))) shares of \(symbol(args)) "
                + "at \(number(args.double("buy_price"))) per share\(dateClause(args, "buy_date")). "
                + "This is record-keeping and places no order."
        case "sell_position":
            return "Record a sale of \(number(args.double("shares_to_sell"))) shares from position "
                + "\(shortId(args)) at \(number(args.double("sell_price"))) per share"
                + "\(dateClause(args, "sell_date")). This reaches profit/loss and tax reports, "
                + "and places no order."
        case "delete_position":
            return "Permanently delete position record \(shortId(args)). "
                + "This erases it as if it never existed — use a sale to record an actual disposal."
        case "record_trade":
            let side = args.string("type") ?? "trade"
            return "Record a \(side) of \(number(args.double("quantity"))) \(symbol(args)) "
                + "at \(number(args.double("price"))) per share\(dateClause(args, "trade_date")). "
                + "This is record-keeping and places no order."
        case "delete_trade":
            return "Permanently delete trade record \(shortId(args)). "
                + "This affects realized profit/loss and tax reports."
        case "add_goal":
            return "Add the goal \(quoted(args.string("title")))."
        case "update_goal":
            return "Rename goal \(shortId(args)) to \(quoted(args.string("title")))."
        case "delete_goal":
            return "Permanently delete goal \(shortId(args))."
        default:
            return nil
        }
    }

    private static func completionCopy(name: String) -> String? {
        switch name {
        case "list_watchlist", "list_transactions", "list_goals": "Done."
        case "add_expense": "Expense created."
        case "update_expense": "Expense updated."
        case "delete_expense": "Expense deleted."
        case "upsert_watchlist_item": "Watchlist updated."
        case "remove_watchlist_item": "Watchlist entry removed."
        case "add_position": "Position recorded."
        case "sell_position": "Sale recorded."
        case "delete_position": "Position record deleted."
        case "record_trade": "Trade recorded."
        case "delete_trade": "Trade record deleted."
        case "add_goal": "Goal created."
        case "update_goal": "Goal updated."
        case "delete_goal": "Goal deleted."
        default: nil
        }
    }

    // MARK: - Argument rendering

    private static func quoted(_ value: String?) -> String {
        guard let value else { return "(untitled)" }
        return "'\(value)'"
    }

    private static func symbol(_ args: ActionArguments) -> String {
        args.string("symbol")?.uppercased() ?? "(no symbol)"
    }

    /// Ids are UUIDs and unreadable in full; the first block is enough for a
    /// person to tell two proposals apart, which is all this needs to do.
    private static func shortId(_ args: ActionArguments) -> String {
        guard let id = args.string("id") else { return "(no id)" }
        return String(id.prefix(8))
    }

    private static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "(unknown)" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    private static func amountClause(_ args: ActionArguments) -> String {
        guard let amount = args.double("amount") else { return "" }
        return " for \(number(amount))"
    }

    private static func dateClause(_ args: ActionArguments, _ key: String) -> String {
        guard let date = args.string(key) else { return "" }
        return " on \(date)"
    }
}
