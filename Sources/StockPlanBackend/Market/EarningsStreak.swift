import Foundation

/// Fills in the `beatStreak` / `missStreak` fields of a symbol's earnings
/// history.
///
/// A streak ends at the quarter that carries it, so every row is true about
/// itself rather than repeating one symbol-level number on all of them. At most
/// one of the two is non-zero; both zero means the row has no comparable result,
/// which is the normal state of the next *scheduled* quarter — so the symbol's
/// headline run is the first row with a non-zero streak, not simply the first
/// row.
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
            return quarter.withStreaks(beat: streak.beat, miss: streak.miss)
        }
    }

    /// Whether the quarter has a comparable result: both an EPS actual and an
    /// EPS estimate. The one definition of "reported" in the codebase — the
    /// earnings teaser selects its rows with it too, so the two cannot drift.
    static func isReported(_ quarter: EarningsResponse) -> Bool {
        quarter.epsActual != nil && quarter.epsEstimated != nil
    }

    /// `true` for a beat, `false` for a miss, nil when the quarter has not
    /// reported a comparable result. Meeting the estimate exactly counts as a
    /// beat, matching how the surprise percentage already reads it.
    private static func outcome(of quarter: EarningsResponse) -> Bool? {
        guard isReported(quarter),
              let actual = quarter.epsActual,
              let estimate = quarter.epsEstimated
        else {
            return nil
        }
        return actual >= estimate
    }
}
