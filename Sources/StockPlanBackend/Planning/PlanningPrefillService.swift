import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Fills the planning screens from what Norviq already knows.
///
/// The point of the two planning tools is that they are wired into the user's real money. A
/// projector you have to type your own portfolio value into is a website; one that opens on
/// your actual holdings and your actual cost of life is the product.
struct PlanningPrefillService: Sendable {
    /// Titles that usually mean housing. Used only to *suggest* a housing line the user can
    /// correct - never to silently reclassify their budget. Housing earns its own field
    /// because it is the one cost that can stop, when a mortgage is paid off.
    private static let housingHints = [
        "rent", "mortgage", "housing", "renda", "aluguel", "hipoteca", "alquiler", "miete",
    ]

    func prefill(userId: UUID, req: Request) async throws -> PlanningPrefill {
        let value = try await portfolioValue(userId: userId, req: req)
        let budget = try await budgetPrefill(userId: userId, on: req.db)
        let age = try await existingRetirementAge(userId: userId, on: req.db)

        return PlanningPrefill(
            currency: budget.currency ?? "EUR",
            portfolioValue: value,
            monthlyCostOfLife: budget.monthlyCostOfLife,
            monthlyByPillar: budget.monthlyByPillar,
            monthlyHousing: budget.monthlyHousing,
            suggestedRetirementAge: age,
            hasBudget: budget.monthlyCostOfLife != nil,
            hasPortfolio: value > 0
        )
    }

    // MARK: Portfolio

    private func portfolioValue(userId: UUID, req: Request) async throws -> Double {
        let stocks = try await Stock.query(on: req.db)
            .filter(\.$userId == userId)
            .all()
        let cash = try await PortfolioCashResolver.totalCashBalance(userId: userId, portfolioId: nil, on: req.db)
        guard stocks.isEmpty == false || cash > 0 else { return 0 }

        let valuation = try await req.application.portfolioValuationService.value(
            stocks: stocks,
            cashBalance: cash,
            asOf: Date(),
            on: req
        )
        return max(0, valuation.totalValue)
    }

    // MARK: Budget

    private struct BudgetPrefill {
        var currency: String?
        var monthlyCostOfLife: Double?
        var monthlyByPillar: [String: Double] = [:]
        var monthlyHousing: Double?
    }

    private func budgetPrefill(userId: UUID, on db: any Database) async throws -> BudgetPrefill {
        guard let snapshot = try await BudgetSnapshot.query(on: db)
            .filter(\.$user.$id == userId)
            .sort(\.$monthStart, .descending)
            .first(),
            let snapshotId = snapshot.id
        else {
            return BudgetPrefill()
        }

        let items = try await BudgetPlanItem.query(on: db)
            .filter(\.$snapshot.$id == snapshotId)
            .all()

        // Reuses the scenario engine's definition of what counts as cost of life, so the
        // planning screens and the scenario impact metrics cannot disagree about it.
        let total = ScenarioBudgetSpending.expenseTotal(
            items: items.map {
                (allocationKind: $0.allocationKind, plannedAmount: $0.plannedAmount, userSharePercent: $0.userSharePercent)
            }
        )

        var byPillar: [String: Double] = [:]
        var housing = 0.0
        for item in items where item.allocationKind != .investmentContribution {
            guard item.plannedAmount.isFinite, item.userSharePercent.isFinite else { continue }
            let share = max(0, min(item.userSharePercent, 100)) / 100
            let amount = max(0, item.plannedAmount) * share
            byPillar[item.pillar.rawValue, default: 0] += amount
            if Self.looksLikeHousing(item.title) {
                housing += amount
            }
        }

        return BudgetPrefill(
            currency: snapshot.currencyCode,
            monthlyCostOfLife: total > 0 && total.isFinite ? total : nil,
            monthlyByPillar: byPillar,
            monthlyHousing: housing > 0 ? housing : nil
        )
    }

    static func looksLikeHousing(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return housingHints.contains { lowered.contains($0) }
    }

    // MARK: Existing plan

    /// Norviq does not store a date of birth, so an age cannot be derived from a goal's target
    /// date. If the user already filled in a portfolio-scoped retirement plan, reuse the ages
    /// they entered there rather than asking again.
    private func existingRetirementAge(userId: UUID, on db: any Database) async throws -> Int? {
        let portfolioIds = try await PortfolioList.query(on: db)
            .filter(\.$userId == userId)
            .all()
            .compactMap(\.id)
        guard portfolioIds.isEmpty == false else { return nil }

        let records = try await RetirementPlanRecord.query(on: db)
            .filter(\.$portfolioId ~~ portfolioIds)
            .all()

        let decoder = JSONDecoder.backendAPI
        let ages = records.compactMap { record -> Int? in
            guard let data = record.inputJSON.data(using: .utf8),
                  let input = try? decoder.decode(RetirementPlanInput.self, from: data)
            else { return nil }
            return input.retirementAge
        }
        return ages.min()
    }
}
