import Foundation

struct PilotOrder: Sendable, Equatable {
    let symbol: String
    let side: LedgerTradeSide
    let quantity: Double
    let price: Double
}

struct PilotRebalancePlan: Sendable, Equatable {
    let orders: [PilotOrder]
    /// Held or target symbols with no price. They are not traded: selling or
    /// sizing blind would be a guess.
    let unpriced: [String]
}

/// Orders that move a portfolio onto target weights. Pure.
///
/// V = cash + priced holdings. Target shares = weight × V ÷ price, with
/// fractional shares allowed. Sells come first so their proceeds fund the
/// buys, and buys are capped at the cash on hand. Moves smaller than
/// max($5, 0.25% of V) are skipped, so that rounding noise does not churn
/// the event log.
enum PilotRebalancePlanner {
    static func plan(weights: [String: Double], holdings: [String: Double], cash: Double, prices: [String: Double]) -> PilotRebalancePlan {
        let symbols = Set(weights.keys).union(holdings.keys)
        let unpriced = symbols.filter { (prices[$0] ?? 0) <= 0 }.sorted()
        let priced = symbols.subtracting(unpriced)

        let value = cash + priced.reduce(0.0) { $0 + (holdings[$1] ?? 0) * prices[$1]! }
        guard value > 0 else { return PilotRebalancePlan(orders: [], unpriced: unpriced) }
        let threshold = max(5, value * 0.0025)

        var sells: [PilotOrder] = []
        var buys: [PilotOrder] = []
        for symbol in priced.sorted() {
            let price = prices[symbol]!
            let current = holdings[symbol] ?? 0
            let target = (weights[symbol] ?? 0) * value / price
            let delta = target - current
            // A dropped symbol (target zero) is always sold out, whatever its size.
            let soldOut = target == 0 && current > 0
            guard soldOut || abs(delta) * price >= threshold else { continue }
            if delta < 0 {
                // Sell-to-zero passes the held quantity unrounded so the ledger
                // closes the position exactly; partial sells never exceed it.
                let quantity = soldOut ? current : min(round6(-delta), current)
                sells.append(PilotOrder(symbol: symbol, side: .sell, quantity: quantity, price: price))
            } else {
                buys.append(PilotOrder(symbol: symbol, side: .buy, quantity: delta, price: price))
            }
        }

        var available = cash + sells.reduce(0.0) { $0 + $1.quantity * $1.price }
        var cappedBuys: [PilotOrder] = []
        for buy in buys {
            let affordable = min(buy.quantity, floor6(available / buy.price))
            guard affordable * buy.price >= threshold else { continue }
            cappedBuys.append(PilotOrder(symbol: buy.symbol, side: .buy, quantity: round6(affordable), price: buy.price))
            available -= round6(affordable) * buy.price
        }
        return PilotRebalancePlan(orders: sells + cappedBuys, unpriced: unpriced)
    }

    private static func round6(_ x: Double) -> Double {
        (x * 1_000_000).rounded() / 1_000_000
    }

    private static func floor6(_ x: Double) -> Double {
        (x * 1_000_000).rounded(.down) / 1_000_000
    }
}
