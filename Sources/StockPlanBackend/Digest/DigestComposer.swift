import Foundation

/// Turns a payload into the short lines every surface shares: the push body,
/// the email subject, the list headline. Deterministic: same payload, same words.
enum DigestComposer {
    /// "Your week: +€412.00 (+1.80%). NVDA did most of it."
    static func headline(_ payload: DigestPayload) -> String {
        guard let primary = payload.holdings.first else {
            return "Your week in Norviq"
        }
        var line = "Your week: \(signedMoney(primary.change, currency: primary.currency))"
        if let pct = primary.changePercent {
            line += " (\(signedPercent(pct)))"
        }
        line += "."
        if let lead = leadMover(payload, in: primary) {
            line += " \(lead.symbol) did most of it."
        }
        return line
    }

    static func subject(_ payload: DigestPayload) -> String {
        guard let primary = payload.holdings.first else { return "Your week in Norviq" }
        var subject = "Your week: \(signedMoney(primary.change, currency: primary.currency))"
        if let pct = primary.changePercent {
            subject += " (\(signedPercent(pct)))"
        }
        return subject
    }

    /// The top mover, if it alone accounts for at least half the week's move
    /// in that currency and in the same direction.
    static func leadMover(_ payload: DigestPayload, in move: DigestCurrencyMove) -> DigestMover? {
        guard move.change != 0,
              let top = payload.movers.first(where: { $0.currency == move.currency }),
              top.contribution.sign == move.change.sign,
              abs(top.contribution) >= abs(move.change) / 2
        else { return nil }
        return top
    }

    // MARK: - Formatting

    static func money(_ value: Double, currency: String) -> String {
        let symbol = currencySymbol(currency)
        let amount = MoneyFormat.number(abs(value))
        let sign = value < 0 ? "-" : ""
        return symbol.count == 1 ? "\(sign)\(symbol)\(amount)" : "\(sign)\(amount) \(symbol)"
    }

    static func signedMoney(_ value: Double, currency: String) -> String {
        value > 0 ? "+" + money(value, currency: currency) : money(value, currency: currency)
    }

    static func signedPercent(_ value: Double) -> String {
        value > 0 ? "+" + MoneyFormat.percent(value) : MoneyFormat.percent(value)
    }

    private static func currencySymbol(_ code: String) -> String {
        switch code.uppercased() {
        case "EUR": "€"
        case "USD": "$"
        case "GBP": "£"
        default: code.uppercased()
        }
    }
}
