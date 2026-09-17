import Foundation

/// Fills in the `beatStreak` / `missStreak` fields of a symbol's earnings
/// history.
///
/// A streak ends at the quarter that carries it, so every row in the response is
/// true about itself rather than repeating one symbol-level number on all of
/// them. The newest *reported* quarter therefore carries the headline "beaten
/// three in a row"; a quarter that is only scheduled — no actual, or no estimate
/// to compare it against — carries nothing, which is what lets a caller tell "no
/// run" apart from "not reported yet".
enum EarningsStreak {
    /// Returns `quarters` in the order they arrived, with the two streak fields
    /// replaced. Input order is not trusted: providers return earnings newest-
    /// first, oldest-first, or unsorted depending on the endpoint, so the run is
    /// counted over the quarters sorted by date.
    static func annotate(_ quarters: [EarningsResponse]) -> [EarningsResponse] {
        // Counted forwards in time so each quarter sees the run it closes; the
        // newest quarter is reached last and therefore carries the longest one.
        let oldestFirst = quarters.indices.sorted { left, right in
            quarters[left].date < quarters[right].date
        }

        var streaks = [Int: (beat: Int, miss: Int)](minimumCapacity: quarters.count)
        var run = 0
        var runIsBeat = true

        for index in oldestFirst {
            guard let outcome = outcome(of: quarters[index]) else {
                // An unreported quarter is not a result, so it carries no run
                // and breaks the one the quarters after it would have inherited.
                streaks[index] = (0, 0)
                run = 0
                continue
            }

            if run > 0, outcome == runIsBeat {
                run += 1
            } else {
                run = 1
                runIsBeat = outcome
            }
            streaks[index] = runIsBeat ? (run, 0) : (0, run)
        }

        return quarters.enumerated().map { index, quarter in
            let streak = streaks[index] ?? (0, 0)
            return EarningsResponse(
                symbol: quarter.symbol,
                date: quarter.date,
                epsActual: quarter.epsActual,
                epsEstimated: quarter.epsEstimated,
                revenueActual: quarter.revenueActual,
                revenueEstimated: quarter.revenueEstimated,
                lastUpdated: quarter.lastUpdated,
                surprisePercent: quarter.surprisePercent,
                hasTranscript: quarter.hasTranscript,
                beatStreak: streak.beat,
                missStreak: streak.miss
            )
        }
    }

    /// `true` for a beat, `false` for a miss, nil when the quarter has not
    /// reported a comparable result. Meeting the estimate exactly counts as a
    /// beat, matching how the surprise percentage already reads it.
    private static func outcome(of quarter: EarningsResponse) -> Bool? {
        guard let actual = quarter.epsActual, let estimate = quarter.epsEstimated else {
            return nil
        }
        return actual >= estimate
    }
}
