import Foundation
import StockPlanShared

/// Rule-based recap archetype. First matching rule wins, so reorder `rules`
/// to change priority. Thresholds are written for a month; the `Int` passed to
/// each predicate is the multiplier (1 for month, 4 for year).
enum PersonalityClassifier {
    typealias Rule = (RecapArchetype, @Sendable (RecapFacts, Int) -> Bool)

    static let rules: [Rule] = [
        (.copycatStrategist, { $0.pilotFollows >= 2 * $1 }),
        (.dividendFarmer, { $0.dividendPayments >= 3 * $1 }),
        (.saver, { $0.goalContributionCount >= 3 * $1 }),
        // The 2x ratio is deliberately not scaled for the year.
        (.comebackKid, { $0.activeDaysSecondHalf >= 5 * $1 && $0.activeDaysSecondHalf >= 2 * $0.activeDaysFirstHalf }),
        (.tickerHunter, { $0.researchTouchesBySymbol.count >= 10 * $1 }),
        (.researcher, { $0.notesWritten + $0.targetsSet >= 5 * $1 }),
        (.disciplinedSizer, { $0.targetsSet >= 3 * $1 }),
        (.patientPlanner, { $0.activeDays >= 10 * $1 && $0.tradeCount <= 2 * $1 }),
    ]

    static func classify(_ facts: RecapFacts, kind: RecapPeriodKind) -> RecapArchetype {
        let multiplier = kind == .year ? 4 : 1
        for (archetype, matches) in rules where matches(facts, multiplier) {
            return archetype
        }
        return .steadyBuilder
    }
}
