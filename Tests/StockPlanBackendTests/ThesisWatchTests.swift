import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Thesis Watch")
struct ThesisWatchTests {
    @Test("classifier identifies material guidance risk")
    func classifierIdentifiesMaterialGuidanceRisk() {
        let result = ThesisWatchClassifier().classify(
            headline: "Company cuts guidance after profit warning",
            summary: nil
        )

        #expect(result.0 == .guidance)
        #expect(result.1 == .high)
    }

    @Test("personalized rank favors a thesis challenge in a large holding")
    func personalizedRankFavorsThesisChallenge() {
        let ranker = ThesisWatchRanker()
        let now = Date()
        let holdingScore = ranker.score(
            relationship: .holding,
            weightPercent: 18,
            severity: .high,
            impact: .challenges,
            publishedAt: now,
            feedback: nil,
            now: now
        )
        let watchlistScore = ranker.score(
            relationship: .watchlist,
            weightPercent: 0,
            severity: .low,
            impact: .neutral,
            publishedAt: now,
            feedback: nil,
            now: now
        )

        #expect(holdingScore > watchlistScore)
    }
}
