import Foundation

/// Pure math behind the `perf.*` achievements. Everything works on a
/// chain-linked index (no amounts), and every predicate answers yes or no, so
/// no return or value ever leaves this type.
enum AchievementPerformance {
    typealias IndexPoint = (day: Date, value: Double)

    /// Chain-linked index (starts 1.0) from daily points, flows removed exactly
    /// as `LeaderboardReturns.timeWeightedPercent` does: a day's change in cost
    /// basis is money moved in or out, not a gain. A day that can't be measured
    /// (no previous value, non-finite or non-positive ratio) carries the index flat.
    static func index(_ points: [LeaderboardReturns.Point]) -> [IndexPoint] {
        guard let first = points.first else { return [] }
        var result: [IndexPoint] = [(first.day, 1.0)]
        result.reserveCapacity(points.count)
        var value = 1.0
        for position in points.indices.dropFirst() {
            let previous = points[position - 1]
            let current = points[position]
            if previous.marketValue > 0 {
                let flow = current.costBasis - previous.costBasis
                let ratio = (current.marketValue - flow) / previous.marketValue
                if ratio.isFinite, ratio > 0 {
                    value *= ratio
                }
            }
            result.append((current.day, value))
        }
        return result
    }

    /// True if any fully covered calendar year (first point ≤ Jan 7, last ≥ Dec 24)
    /// ended above its start.
    static func hasPositiveYear(_ index: [IndexPoint], calendar: Calendar) -> Bool {
        let byYear = Dictionary(grouping: index) { calendar.component(.year, from: $0.day) }
        for (year, points) in byYear {
            let sorted = points.sorted { $0.day < $1.day }
            guard let first = sorted.first, let last = sorted.last,
                  let coverageStart = calendar.date(from: DateComponents(year: year, month: 1, day: 7)),
                  let coverageEnd = calendar.date(from: DateComponents(year: year, month: 12, day: 24))
            else { continue }
            let startsInTime = calendar.startOfDay(for: first.day) <= coverageStart
            let endsInTime = calendar.startOfDay(for: last.day) >= coverageEnd
            if startsInTime, endsInTime, last.value > first.value {
                return true
            }
        }
        return false
    }

    /// Calendar days the index must span inside the trailing year.
    static let benchmarkMinimumSpanDays = 330

    /// Trailing 365-day index return > benchmark close-to-close return over the
    /// same days. Needs ≥ 330 days of points: the measured span, from the base
    /// point to the last point on or before `asOf`, must cover at least 330
    /// calendar days. (A span, not a count: backfilled snapshots exist only on
    /// trading days, about 252 a year.)
    static func beatBenchmark(_ index: [IndexPoint], benchmark: [(day: Date, close: Double)], asOf: Date) -> Bool {
        let sorted = index.sorted { $0.day < $1.day }
        let windowStart = PortfolioSnapshotValuator.addDays(asOf, days: -365)
        // Base: the last point on or before the window start, else the first one inside it.
        guard let end = sorted.last(where: { $0.day <= asOf }),
              let base = sorted.last(where: { $0.day <= windowStart }) ?? sorted.first(where: { $0.day > windowStart }),
              base.day < end.day,
              base.value > 0
        else { return false }
        let spanDays = (end.day.timeIntervalSince(base.day) / 86400).rounded()
        guard spanDays >= Double(benchmarkMinimumSpanDays) else { return false }

        let bars = benchmark.sorted { $0.day < $1.day }
        guard let benchmarkStart = close(in: bars, onOrBefore: base.day),
              let benchmarkEnd = close(in: bars, onOrBefore: end.day),
              benchmarkStart.day < benchmarkEnd.day,
              benchmarkStart.close > 0
        else { return false }

        let indexReturn = end.value / base.value - 1
        let benchmarkReturn = benchmarkEnd.close / benchmarkStart.close - 1
        return indexReturn.isFinite && benchmarkReturn.isFinite && indexReturn > benchmarkReturn
    }

    /// The bar on or before `day`, falling back to the first bar within a week
    /// after it (a base day on a weekend or holiday).
    private static func close(in bars: [(day: Date, close: Double)], onOrBefore day: Date) -> (day: Date, close: Double)? {
        if let bar = bars.last(where: { $0.day <= day }) {
            return bar
        }
        let limit = PortfolioSnapshotValuator.addDays(day, days: 7)
        return bars.first { $0.day > day && $0.day <= limit }
    }

    /// Drawdown that qualifies as "≥ 10% from a running peak".
    static let comebackDrawdown = 0.10

    /// A drawdown of ≥ 10% from a running peak, later followed by a new value ≥ that peak.
    static func hasComeback(_ index: [IndexPoint]) -> Bool {
        var peak: Double?
        var fellFarEnough = false
        for point in index.sorted(by: { $0.day < $1.day }) {
            guard let currentPeak = peak else {
                peak = point.value
                continue
            }
            if point.value >= currentPeak {
                if fellFarEnough {
                    return true
                }
                peak = point.value
            } else if currentPeak > 0, point.value / currentPeak <= 1 - comebackDrawdown + 1e-9 {
                fellFarEnough = true
            }
        }
        return false
    }
}
