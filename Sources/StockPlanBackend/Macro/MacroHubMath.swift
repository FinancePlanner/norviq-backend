import Foundation

/// Pure helpers for Economy hub signals (Sahm rule, risk label).
enum MacroHubMath {
    /// Sahm rule: 3-month average of unemployment minus the minimum of the
    /// 3-month averages over the prior 12 months. Trigger typically ≥ 0.50 pp.
    /// `values` must be chronological (oldest → newest). Returns nil if < 15 points.
    static func sahmRule(unemploymentValues: [Double]) -> Double? {
        guard unemploymentValues.count >= 15 else { return nil }
        let threeMonthAvgs: [Double] = (2 ..< unemploymentValues.count).compactMap { end in
            let window = unemploymentValues[(end - 2) ... end]
            guard window.count == 3 else { return nil }
            return window.reduce(0, +) / 3.0
        }
        guard threeMonthAvgs.count >= 13 else { return nil }
        let current = threeMonthAvgs[threeMonthAvgs.count - 1]
        let lookback = threeMonthAvgs[(threeMonthAvgs.count - 13) ..< (threeMonthAvgs.count - 1)]
        guard let trough = lookback.min() else { return nil }
        return ((current - trough) * 100).rounded() / 100
    }

    /// Map Sahm + official recession flag → coarse risk label.
    static func riskLabel(sahm: Double?, officialRecession: Bool?) -> String {
        if officialRecession == true {
            return "elevated"
        }
        guard let sahm else { return "low" }
        if sahm >= 0.50 {
            return "elevated"
        }
        if sahm >= 0.30 {
            return "watch"
        }
        return "low"
    }
}
