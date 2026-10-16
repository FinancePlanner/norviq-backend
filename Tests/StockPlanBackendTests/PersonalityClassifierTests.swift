import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Personality classifier")
struct PersonalityClassifierTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let expected: RecapArchetype
        let facts: RecapFacts
        var testDescription: String {
            expected.rawValue
        }
    }

    static let rows: [Row] = [
        Row(expected: .copycatStrategist, facts: RecapFacts(pilotFollows: 2)),
        Row(expected: .dividendFarmer, facts: RecapFacts(dividendPayments: 3)),
        Row(expected: .saver, facts: RecapFacts(goalContributionCount: 3)),
        Row(expected: .comebackKid, facts: RecapFacts(activeDaysFirstHalf: 2, activeDaysSecondHalf: 5)),
        Row(expected: .tickerHunter, facts: RecapFacts(
            researchTouchesBySymbol: Dictionary(uniqueKeysWithValues: (0 ..< 10).map { ("S\($0)", 1) })
        )),
        Row(expected: .researcher, facts: RecapFacts(notesWritten: 3, targetsSet: 2)),
        Row(expected: .disciplinedSizer, facts: RecapFacts(targetsSet: 3)),
        Row(expected: .patientPlanner, facts: RecapFacts(activeDays: 10, tradeCount: 2)),
        Row(expected: .steadyBuilder, facts: RecapFacts(activeDays: 4, tradeCount: 5)),
    ]

    @Test("each archetype hits its rule for a month", arguments: rows)
    func monthRows(row: Row) {
        #expect(PersonalityClassifier.classify(row.facts, kind: .month) == row.expected)
    }

    @Test func firstMatchWins() {
        let facts = RecapFacts(dividendPayments: 5, pilotFollows: 2)
        #expect(PersonalityClassifier.classify(facts, kind: .month) == .copycatStrategist)
    }

    @Test func yearScalesThresholds() {
        let three = RecapFacts(dividendPayments: 3)
        #expect(PersonalityClassifier.classify(three, kind: .month) == .dividendFarmer)
        #expect(PersonalityClassifier.classify(three, kind: .year) == .steadyBuilder)
        let twelve = RecapFacts(dividendPayments: 12)
        #expect(PersonalityClassifier.classify(twelve, kind: .year) == .dividendFarmer)
    }

    @Test func comebackRatioIsNotScaledForYear() {
        let facts = RecapFacts(activeDaysFirstHalf: 10, activeDaysSecondHalf: 20)
        #expect(PersonalityClassifier.classify(facts, kind: .year) != .steadyBuilder)
        let flat = RecapFacts(activeDaysFirstHalf: 11, activeDaysSecondHalf: 20)
        #expect(PersonalityClassifier.classify(flat, kind: .year) == .steadyBuilder)
    }

    /// A user who joined mid-period has no first half to come back from.
    @Test func comebackNeedsFirstHalfPresence() {
        let joinedMidMonth = RecapFacts(activeDaysFirstHalf: 0, activeDaysSecondHalf: 10)
        #expect(PersonalityClassifier.classify(joinedMidMonth, kind: .month) != .comebackKid)
        let returned = RecapFacts(activeDaysFirstHalf: 1, activeDaysSecondHalf: 10)
        #expect(PersonalityClassifier.classify(returned, kind: .month) == .comebackKid)
    }

    @Test func emptyFactsDefault() {
        #expect(PersonalityClassifier.classify(RecapFacts(), kind: .month) == .steadyBuilder)
        #expect(!RecapFacts().hasAnyActivity)
        #expect(RecapFacts(activeDays: 1).hasAnyActivity)
    }
}
