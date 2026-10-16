import Foundation
import StockPlanShared

/// Pure: turns one user's facts for one period into a recap deck.
enum RecapDeckBuilder {
    static let schemaVersion = 1
    static let minFullDeckSlides = 4
    static let minFullDeckActiveDays = 7
    static let maxTopTickers = 5

    static func build(facts: RecapFacts, period: RecapPeriod) -> RecapDeck {
        let intro = RecapSlide.intro(RecapIntroSlide(periodLabel: period.label, activeDays: facts.activeDays))
        let nextLabel = period.next.label

        func deck(
            archetype: RecapArchetype?, firstChapter: Bool, missedYou: Bool, slides: [RecapSlide]
        ) -> RecapDeck {
            RecapDeck(
                kind: period.kind,
                key: period.key,
                periodLabel: period.label,
                archetype: archetype,
                isFirstChapter: firstChapter,
                isMissedYou: missedYou,
                slides: slides,
                schemaVersion: schemaVersion
            )
        }

        // No activity, or activity with nothing to show (only XP, AI requests,
        // board posts...): a first chapter needs at least one middle slide.
        let middle = facts.hasAnyActivity ? middleSlides(facts) : []
        guard !middle.isEmpty else {
            return deck(archetype: nil, firstChapter: false, missedYou: true, slides: [
                intro,
                .missedYou(RecapMissedYouSlide(
                    bestStreakDays: facts.bestStreakEverDays, totalBadges: facts.totalBadgesEver
                )),
                .outro(RecapOutroSlide(isFirstChapter: false, nextPeriodLabel: nextLabel)),
            ])
        }

        if middle.count >= minFullDeckSlides, facts.activeDays >= minFullDeckActiveDays {
            let archetype = PersonalityClassifier.classify(facts, kind: period.kind)
            return deck(
                archetype: archetype, firstChapter: false, missedYou: false,
                slides: [intro] + middle + [
                    .personality(RecapPersonalitySlide(archetype: archetype)),
                    .outro(RecapOutroSlide(isFirstChapter: false, nextPeriodLabel: nextLabel)),
                ]
            )
        }

        return deck(
            archetype: nil, firstChapter: true, missedYou: false,
            slides: [intro] + Array(middle.prefix(2)) + [
                .outro(RecapOutroSlide(isFirstChapter: true, nextPeriodLabel: nextLabel)),
            ]
        )
    }

    /// Eligible middle slides in canonical order.
    private static func middleSlides(_ facts: RecapFacts) -> [RecapSlide] {
        var slides: [RecapSlide] = []

        if facts.longestStreakDays >= 2 {
            slides.append(.streak(RecapStreakSlide(
                longestStreakDays: facts.longestStreakDays, activeDays: facts.activeDays
            )))
        }

        if facts.researchTouchesBySymbol.count >= 3 {
            let top = facts.researchTouchesBySymbol
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(maxTopTickers)
                .map { RecapTickerStat(symbol: $0.key, touches: $0.value) }
            slides.append(.topTickers(RecapTopTickersSlide(tickers: top)))
        }

        if facts.tradeCount >= 1 {
            let mostTraded = facts.tradesBySymbol
                .min { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }?.key
            slides.append(.trades(RecapTradesSlide(
                tradeCount: facts.tradeCount, buyCount: facts.buyCount,
                sellCount: facts.sellCount, mostTradedSymbol: mostTraded
            )))
        }

        if facts.notesWritten + facts.watchlistAdded + facts.targetsSet >= 1 {
            slides.append(.research(RecapResearchSlide(
                notesWritten: facts.notesWritten, watchlistAdded: facts.watchlistAdded,
                targetsSet: facts.targetsSet, targetsHit: facts.targetsHit
            )))
        }

        if !facts.growth.isEmpty {
            slides.append(.growth(RecapGrowthSlide(growth: facts.growth)))
        }

        if facts.dividendPayments >= 1 {
            slides.append(.dividends(RecapDividendsSlide(
                received: facts.dividendsReceived, paymentCount: facts.dividendPayments,
                payerCount: facts.dividendPayers
            )))
        }

        if facts.goalContributionCount >= 1 {
            slides.append(.goals(RecapGoalsSlide(
                contributed: facts.goalContributions, contributionCount: facts.goalContributionCount
            )))
        }

        if !facts.badgesEarned.isEmpty {
            slides.append(.badges(RecapBadgesSlide(badges: facts.badgesEarned, xpEarned: facts.xpEarned)))
        }

        return slides
    }
}
