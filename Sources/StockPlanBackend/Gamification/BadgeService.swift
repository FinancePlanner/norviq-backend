import Fluent
import Foundation
import StockPlanShared
import Vapor

protocol BadgeService: Sendable {
    func evaluateBadges(userId: UUID, req: Request, on db: any Database) async throws -> BadgesListResponse
}

struct DefaultBadgeService: BadgeService {
    func evaluateBadges(userId: UUID, req: Request, on db: any Database) async throws -> BadgesListResponse {
        // Load all already-earned badges for this user
        let earnedRecords = try await UserBadge.query(on: db)
            .filter(\.$userId == userId)
            .all()

        let formatter = ISO8601DateFormatter()

        // Build a lookup: [BadgeType: [BadgeTier: Date]]
        var earnedLookup: [BadgeType: [BadgeTier: Date]] = [:]
        for record in earnedRecords {
            earnedLookup[record.badgeType, default: [:]][record.tier] = record.earnedAt
        }

        // Evaluate raw counts for each badge type
        let rawCounts = try await computeRawCounts(userId: userId, req: req, on: db)

        var badgeResponses: [BadgeProgressResponse] = []
        var newlyEarned: [UserBadge] = []

        for definition in BadgeDefinitions.all {
            let count = rawCounts[definition.type] ?? 0
            let earnedTiersForBadge = earnedLookup[definition.type] ?? [:]

            // Determine which tiers are earned
            var earnedTierInfos: [EarnedTierInfo] = []
            let now = Date()

            for tier in BadgeTier.allCases {
                let threshold = definition.threshold(for: tier)
                if count >= threshold {
                    if let earnedDate = earnedTiersForBadge[tier] {
                        // Already persisted
                        earnedTierInfos.append(EarnedTierInfo(
                            tier: tier,
                            earnedAt: formatter.string(from: earnedDate)
                        ))
                    } else {
                        // Newly earned — persist it
                        let badge = UserBadge(
                            userId: userId,
                            badgeType: definition.type,
                            tier: tier,
                            earnedAt: now
                        )
                        newlyEarned.append(badge)
                        earnedTierInfos.append(EarnedTierInfo(
                            tier: tier,
                            earnedAt: formatter.string(from: now)
                        ))
                    }
                }
            }

            let currentTier = earnedTierInfos.last?.tier
            let nextTier: BadgeTier?
            let progress: Double
            let targetCount: Int

            if currentTier == .gold {
                nextTier = nil
                progress = 1.0
                targetCount = definition.goldThreshold
            } else if let current = currentTier {
                // Next tier after current
                let allTiers = BadgeTier.allCases
                let currentIndex = allTiers.firstIndex(of: current)!
                let next = allTiers[allTiers.index(after: currentIndex)]
                nextTier = next
                let nextThreshold = definition.threshold(for: next)
                targetCount = nextThreshold
                progress = min(Double(count) / Double(nextThreshold), 1.0)
            } else {
                // No tier earned yet, working toward bronze
                nextTier = .bronze
                targetCount = definition.bronzeThreshold
                progress = min(Double(count) / Double(definition.bronzeThreshold), 1.0)
            }

            badgeResponses.append(BadgeProgressResponse(
                type: definition.type,
                title: definition.title,
                description: definition.description,
                iconName: definition.iconName,
                currentTier: currentTier,
                nextTier: nextTier,
                progress: progress,
                currentCount: count,
                targetCount: targetCount,
                earnedTiers: earnedTierInfos
            ))
        }

        // Persist newly earned badges
        if !newlyEarned.isEmpty {
            for badge in newlyEarned {
                do {
                    try await badge.save(on: db)
                } catch {
                    let reflected = String(reflecting: error)
                    if reflected.contains("user_badges_user_id_badge_type_tier")
                        || reflected.contains("duplicate key")
                    {
                        req.logger.debug("badge already persisted user=\(userId) type=\(badge.badgeType.rawValue) tier=\(badge.tier.rawValue)")
                    } else {
                        req.logger.error("failed to persist badge user=\(userId) type=\(badge.badgeType.rawValue) tier=\(badge.tier.rawValue) error=\(error)")
                        throw error
                    }
                }
            }
        }

        let totalEarned = badgeResponses.reduce(0) { $0 + $1.earnedTiers.count }
        let totalAvailable = BadgeDefinitions.all.count * BadgeTier.allCases.count

        return BadgesListResponse(
            badges: badgeResponses,
            totalEarnedTiers: totalEarned,
            totalAvailableTiers: totalAvailable
        )
    }
}

// MARK: - Raw Count Computation

private extension DefaultBadgeService {
    func computeRawCounts(userId: UUID, req: Request, on db: any Database) async throws -> [BadgeType: Int] {
        var counts: [BadgeType: Int] = [:]

        // --- First Purchase & Investor: count manual holdings plus broker/import buy activity ---
        let stocks = try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .all()
        let manualHoldingCount = stocks.count(where: { stock in
            stock.sourceProvider == nil && stock.sourceAccountId == nil
        })
        let importedHoldingCount = max(stocks.count - manualHoldingCount, 0)

        let accounts = try await Account.query(on: db).filter(\.$userId == userId).all()
        let accountIds = Set(accounts.compactMap(\.id))

        var buyCount = 0
        if !accountIds.isEmpty {
            buyCount = try await Transaction.query(on: db)
                .filter(\.$accountId ~~ accountIds)
                .filter(\.$type == "buy")
                .count()
        }
        let investmentCount = manualHoldingCount + max(importedHoldingCount, buyCount)
        counts[.firstPurchase] = investmentCount
        counts[.investor] = investmentCount

        // --- News Reader: count newsViewed activities ---
        let newsViewCount = try await UserActivity.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$type == .newsViewed)
            .count()
        counts[.newsReader] = newsViewCount

        // --- Saver, Frugal Fun, Growth Mindset: from monthly reports ---
        let monthlyReports = try await req.expensesService.getMonthlyReports(
            userId: userId, from: nil, to: nil, on: db
        )

        // Saver: count months with positive savings
        var saverMonths = 0
        for report in monthlyReports {
            if report.salary > 0, report.actual < report.salary {
                saverMonths += 1
            }
        }
        counts[.saver] = saverMonths

        // Frugal Fun: count months where fun actual < fun planned
        var frugalMonths = 0
        for report in monthlyReports {
            let funActual = report.pillarActuals[BudgetPillar.fun.rawValue] ?? 0
            let funPlan = report.pillarPlans[BudgetPillar.fun.rawValue] ?? 0
            if funPlan > 0, funActual <= funPlan {
                frugalMonths += 1
            }
        }
        counts[.frugalFun] = frugalMonths

        // Growth Mindset: count consecutive months with increasing savings (newest first)
        var growthStreak = 0
        let reversedReports = monthlyReports.reversed().map(\.self) // newest first
        if reversedReports.count >= 2 {
            for i in 0 ..< (reversedReports.count - 1) {
                let currentSavings = reversedReports[i].salary - reversedReports[i].actual
                let previousSavings = reversedReports[i + 1].salary - reversedReports[i + 1].actual
                if currentSavings > previousSavings, reversedReports[i].salary > 0 {
                    growthStreak += 1
                } else {
                    break
                }
            }
        }
        counts[.growthMindset] = growthStreak

        // --- Spending Detox: max consecutive no-expense days ---
        let expenses = try await Expense.query(on: db)
            .filter(\.$user.$id == userId)
            .sort(\.$occurredOn, .ascending)
            .all()

        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())

        if expenses.isEmpty {
            // No expenses ever → check days since account creation
            if let user = try await User.find(userId, on: db),
               let createdAt = user.createdAt
            {
                let daysSinceCreation = calendar.dateComponents([.day], from: calendar.startOfDay(for: createdAt), to: today).day ?? 0
                counts[.spendingDetox] = max(daysSinceCreation, 0)
            } else {
                counts[.spendingDetox] = 0
            }
        } else {
            // Build a set of dates with expenses
            var expenseDates = Set<Date>()
            for expense in expenses {
                let day = calendar.startOfDay(for: expense.occurredOn)
                expenseDates.insert(day)
            }

            // Find max gap between consecutive expense dates
            let sortedDates = expenseDates.sorted()
            var maxGap = 0

            // Check gap from first expense date to today (for trailing gap)
            if let lastDate = sortedDates.last {
                let trailingGap = calendar.dateComponents([.day], from: lastDate, to: today).day ?? 0
                maxGap = max(maxGap, trailingGap - 1) // -1 because lastDate itself is an expense day
            }

            // Check gaps between expense dates
            for i in 1 ..< sortedDates.count {
                let gap = calendar.dateComponents([.day], from: sortedDates[i - 1], to: sortedDates[i]).day ?? 0
                let noSpendDays = gap - 1 // days between two expense days
                maxGap = max(maxGap, noSpendDays)
            }

            counts[.spendingDetox] = max(maxGap, 0)
        }

        return counts
    }
}

// MARK: - Application / Request Extension

extension Application {
    private struct BadgeServiceKey: StorageKey {
        typealias Value = any BadgeService
    }

    var badgeService: any BadgeService {
        get { storage[BadgeServiceKey.self] ?? DefaultBadgeService() }
        set { storage[BadgeServiceKey.self] = newValue }
    }
}

extension Request {
    var badgeService: any BadgeService {
        application.badgeService
    }

    func reconcileBadges(userId: UUID, on db: any Database) async {
        do {
            _ = try await badgeService.evaluateBadges(userId: userId, req: self, on: db)
        } catch {
            logger.warning("badge reconciliation failed user=\(userId) error=\(error)")
        }
    }
}
