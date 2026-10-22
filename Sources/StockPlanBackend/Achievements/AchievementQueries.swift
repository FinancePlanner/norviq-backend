import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Read and showcase operations of `AchievementService`, kept apart from the
/// evaluation engine in `AchievementService.swift`.
extension AchievementService {
    static let showcaseLimit = 3
    static let unseenLimit = 20

    /// Definition for a stored key, including `legacy.<BadgeType>` keys.
    private static func definition(forKey key: String) -> AchievementDefinition? {
        if let found = AchievementCatalogue.definition(key) { return found }
        guard key.hasPrefix("legacy."), let badge = BadgeType(rawValue: String(key.dropFirst("legacy.".count))) else { return nil }
        return AchievementCatalogue.legacyDefinition(for: badge)
    }

    private static func copy(_ definition: AchievementDefinition, _ language: AchievementLanguage) -> (title: String, description: String) {
        definition.copy[language] ?? definition.copy[.en] ?? (definition.key, "")
    }

    static func list(userId: UUID, language: AchievementLanguage, ctx: AchievementContext) async throws -> AchievementsResponseDTO {
        let rows = try await UserAchievement.query(on: ctx.db).filter(\.$user.$id == userId).all()
        var rowsByKey: [String: [String: UserAchievement]] = [:]
        for row in rows { rowsByKey[row.achievementKey, default: [:]][row.tier] = row }

        let hasLegacy = rows.contains { $0.achievementKey.hasPrefix("legacy.") }
        var definitions = AchievementCatalogue.all
        if hasLegacy { definitions += BadgeType.allCases.map { AchievementCatalogue.legacyDefinition(for: $0) } }

        func earnedCount(_ definition: AchievementDefinition) -> Int {
            definition.tiers.filter { rowsByKey[definition.key]?[$0.tier] != nil }.count
        }

        // Progress only where it is cheap and allowed: never for performance,
        // hidden, sweep-only or legacy definitions, nor fully earned ones.
        let measureKeys = Set(definitions.filter {
            !$0.isPerformance && !$0.isHidden && !$0.sweepOnly && !$0.key.hasPrefix("legacy.")
                && earnedCount($0) < $0.tiers.count
        }.map(\.key))
        let metrics = measureKeys.isEmpty ? [:] : try await AchievementMetrics.measure(userId: userId, keys: measureKeys, ctx: ctx)

        // An unearned hidden achievement is listed under an opaque key: the
        // real key would give away what it is.
        let hiddenOrdinals = Dictionary(uniqueKeysWithValues: AchievementCatalogue.all.filter(\.isHidden)
            .enumerated().map { ($1.key, $0 + 1) })

        var dtos: [AchievementDTO] = []
        // Hidden achievements stay out of `unlocked`/`total`, earned or not.
        var unlocked = 0, total = 0, hiddenRemaining = 0
        for definition in definitions {
            let isLegacy = definition.key.hasPrefix("legacy.")
            let earned = earnedCount(definition)
            let maxed = earned == definition.tiers.count
            if !isLegacy, !definition.isHidden {
                total += definition.tiers.count
                unlocked += earned
            }
            if definition.isHidden, !maxed { hiddenRemaining += 1 }

            if definition.isHidden, earned == 0 {
                dtos.append(AchievementDTO(
                    key: "hidden.\(hiddenOrdinals[definition.key] ?? 0)", category: definition.category.rawValue,
                    title: hiddenTitle(language), description: hiddenDescription(language), iconKey: "lock",
                    state: "hidden", currentTier: nil, progress: nil, isPerformance: definition.isPerformance,
                    tiers: definition.tiers.map {
                        AchievementTierDTO(tier: $0.tier, threshold: nil, xp: 0, unlockId: nil, unlockedAt: nil, showcaseRank: nil)
                    }
                ))
                continue
            }

            let metric = metrics[definition.key]
            let state = maxed ? "earned" : (earned > 0 || (metric ?? 0) > 0 ? "inProgress" : "locked")
            let heldTiers = definition.tiers.filter { rowsByKey[definition.key]?[$0.tier] != nil }
            var progress: AchievementProgressDTO?
            if !maxed, !definition.isPerformance, !definition.isHidden, let metric,
               let next = definition.tiers.first(where: { rowsByKey[definition.key]?[$0.tier] == nil }) {
                progress = AchievementProgressDTO(current: min(metric, next.threshold), target: next.threshold)
            }
            let text = copy(definition, language)
            dtos.append(AchievementDTO(
                key: definition.key, category: definition.category.rawValue,
                title: text.title, description: text.description, iconKey: definition.iconKey,
                state: state, currentTier: heldTiers.last?.tier, progress: progress,
                isPerformance: definition.isPerformance,
                tiers: definition.tiers.map { spec in
                    let row = rowsByKey[definition.key]?[spec.tier]
                    return AchievementTierDTO(
                        tier: spec.tier, threshold: spec.threshold, xp: spec.xp,
                        unlockId: row?.id, unlockedAt: row?.unlockedAt, showcaseRank: row?.showcaseRank
                    )
                }
            ))
        }

        let categories = AchievementCategory.allCases
            .filter { $0 != .classic || hasLegacy }
            .map { AchievementCategoryDTO(key: $0.rawValue, title: $0.title(language)) }
        return AchievementsResponseDTO(
            summary: AchievementSummaryDTO(unlocked: unlocked, total: total, hiddenRemaining: hiddenRemaining),
            categories: categories, achievements: dtos
        )
    }

    static func unseen(userId: UUID, language: AchievementLanguage, on db: any Database) async throws -> [AchievementUnlockDTO] {
        let rows = try await UserAchievement.query(on: db)
            .filter(\.$user.$id == userId)
            .filter(\.$seenAt == nil)
            .filter(\.$source ~~ [AchievementSource.live.rawValue, AchievementSource.sweep.rawValue])
            .sort(\.$unlockedAt, .ascending)
            .limit(unseenLimit)
            .all()
        return rows.compactMap { row in
            guard let id = row.id, let definition = definition(forKey: row.achievementKey) else { return nil }
            let text = copy(definition, language)
            return AchievementUnlockDTO(
                id: id, key: row.achievementKey, tier: row.tier, title: text.title, description: text.description,
                iconKey: definition.iconKey, xp: definition.tiers.first { $0.tier == row.tier }?.xp ?? 0,
                unlockedAt: row.unlockedAt
            )
        }
    }

    /// Only the caller's still-unseen rows change; other users' ids are ignored.
    static func markSeen(userId: UUID, ids: [UUID], on db: any Database) async throws {
        guard !ids.isEmpty else { return }
        try await UserAchievement.query(on: db)
            .filter(\.$user.$id == userId)
            .filter(\.$id ~~ ids)
            .filter(\.$seenAt == nil)
            .set(\.$seenAt, to: Date())
            .update()
    }

    /// Replaces the caller's showcase (ranks 1…n in order). Takes a context,
    /// not a bare database, because it returns the refreshed listing.
    static func setShowcase(
        userId: UUID, items: [AchievementShowcaseItem], language: AchievementLanguage, ctx: AchievementContext
    ) async throws -> AchievementsResponseDTO {
        guard items.count <= showcaseLimit else { throw Abort(.badRequest, reason: "At most \(showcaseLimit) showcase items.") }
        guard Set(items.map { "\($0.key)|\($0.tier)" }).count == items.count else {
            throw Abort(.badRequest, reason: "Duplicate showcase items.")
        }
        try await ctx.db.transaction { tx in
            var matches: [UserAchievement] = []
            for item in items {
                guard let row = try await UserAchievement.query(on: tx)
                    .filter(\.$user.$id == userId)
                    .filter(\.$achievementKey == item.key)
                    .filter(\.$tier == item.tier)
                    .first()
                else { throw Abort(.badRequest, reason: "Achievement not earned.") }
                matches.append(row)
            }
            try await UserAchievement.query(on: tx)
                .filter(\.$user.$id == userId)
                .filter(\.$showcaseRank != nil)
                .set(\.$showcaseRank, to: nil)
                .update()
            for (index, row) in matches.enumerated() {
                try await UserAchievement.query(on: tx)
                    .filter(\.$id == row.requireID())
                    .set(\.$showcaseRank, to: index + 1)
                    .update()
            }
        }
        return try await list(userId: userId, language: language, ctx: ctx)
    }

    private static func hiddenTitle(_ language: AchievementLanguage) -> String { "???" }

    private static func hiddenDescription(_ language: AchievementLanguage) -> String {
        language == .pt ? "Continua a explorar." : "Keep exploring."
    }
}
