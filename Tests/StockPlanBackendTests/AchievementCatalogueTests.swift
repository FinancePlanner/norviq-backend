@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("AchievementCatalogue")
struct AchievementCatalogueTests {
    @Test func keysAreUnique() {
        let keys = AchievementCatalogue.all.map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(keys.count == 35)
    }

    @Test func tiersAscend() {
        for def in AchievementCatalogue.all {
            #expect(!def.tiers.isEmpty, "\(def.key)")
            let thresholds = def.tiers.map(\.threshold)
            #expect(zip(thresholds, thresholds.dropFirst()).allSatisfy { $0 < $1 }, "\(def.key)")
            for spec in def.tiers {
                #expect(["bronze", "silver", "gold", ""].contains(spec.tier), "\(def.key)")
            }
            if def.tiers.count == 1 {
                #expect(def.tiers[0].tier == "", "\(def.key)")
            } else {
                #expect(def.tiers.map(\.tier) == ["bronze", "silver", "gold"], "\(def.key)")
            }
        }
    }

    @Test func everyDefinitionHasBothLanguages() {
        for def in AchievementCatalogue.all + BadgeType.allCases.map(AchievementCatalogue.legacyDefinition(for:)) {
            for lang in [AchievementLanguage.en, .pt] {
                let c = def.copy[lang]
                #expect(!(c?.title.isEmpty ?? true), "\(def.key) \(lang)")
                #expect(!(c?.description.isEmpty ?? true), "\(def.key) \(lang)")
            }
        }
    }

    @Test func xpValues() {
        #expect(AchievementCatalogue.definition("discipline.check_in")?.tiers.map(\.xp) == [25, 50, 100])
        #expect(AchievementCatalogue.definition("perf.comeback")?.tiers.map(\.xp) == [100])
        #expect(AchievementCatalogue.definition("hidden.founding_member")?.tiers.map(\.xp) == [50])
        #expect(AchievementCatalogue.definition("start.first_holding")?.tiers.map(\.xp) == [25])
    }

    @Test func flags() throws {
        #expect(try #require(AchievementCatalogue.definition("craft.diversified")?.sweepOnly))
        #expect(try #require(AchievementCatalogue.definition("craft.patient_capital")?.sweepOnly))
        #expect(try #require(AchievementCatalogue.definition("perf.beat_benchmark")?.isPerformance))
        #expect(try #require(AchievementCatalogue.definition("hidden.founding_member")?.isHidden))
        #expect(AchievementCatalogue.definition("nope") == nil)
    }

    @Test func languageParsing() {
        for h in ["pt-BR", "pt", "PT-pt;q=0.9, en;q=0.8"] {
            #expect(AchievementLanguage.from(acceptLanguage: h) == .pt, "\(h)")
        }
        for h in ["en-US", nil, "", "en;q=0.9, pt;q=0.8"] {
            #expect(AchievementLanguage.from(acceptLanguage: h) == .en)
        }
    }

    @Test func legacyDefinitionsCoverAllBadgeTypes() {
        for type in BadgeType.allCases {
            let def = AchievementCatalogue.legacyDefinition(for: type)
            let badge = BadgeDefinitions.definition(for: type)
            #expect(def.key == "legacy.\(type.rawValue)")
            #expect(def.category == .classic)
            #expect(def.tiers.map(\.tier) == ["bronze", "silver", "gold"])
            #expect(def.tiers.map(\.threshold) == [badge.bronzeThreshold, badge.silverThreshold, badge.goldThreshold])
            #expect(def.tiers.map(\.xp) == [25, 50, 100])
            #expect(def.copy[.en]?.title == badge.title)
            #expect(def.iconKey == badge.iconName)
        }
    }
}
