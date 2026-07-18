import Fluent
import Foundation
import StockPlanShared

struct TaxDragAnalytics: Sendable {
    struct Input: Sendable {
        let accountIDs: [UUID]
        let taxYear: Int
        let profile: TaxProfileRequest
        let pack: ConfiguredTaxRulePack
        let realizedTax: Decimal
        let embeddedLiability: Decimal
        let positions: [Position]
    }

    func projection(
        input: Input,
        on database: any Database
    ) async throws -> TaxDragProjection {
        let interval = yearInterval(input.taxYear)
        let dividends = input.accountIDs.isEmpty ? [] : try await Dividend.query(on: database)
            .filter(\.$accountId ~~ input.accountIDs)
            .filter(\.$payDate >= interval.start)
            .filter(\.$payDate < interval.end)
            .all()
        let dividendIncome = dividends.reduce(Decimal.zero) { $0 + Decimal(max(0, $1.amount)) }
        let incomeRate = max(
            0,
            input.profile.marginalIncomeTaxRate
                ?? input.profile.shortTermCapitalGainsRate
                ?? input.pack.rate(isLongTerm: false, profile: input.profile)
                ?? 0
        )
        let dividendTax = dividendIncome * incomeRate
        let factor = annualizationFactor(taxYear: input.taxYear, start: interval.start)
        let projectedRealized = input.realizedTax * factor
        let projectedIncome = dividendTax * factor
        let projectedTax = projectedRealized + projectedIncome
        let portfolioValue = input.positions.reduce(Decimal.zero) { partial, position in
            partial + Decimal(max(0, position.quantity * (position.lastPrice ?? position.averageCost)))
        }
        let ratio = portfolioValue > 0 ? projectedTax / portfolioValue : nil
        let currency = input.profile.reportingCurrency
        return TaxDragProjection(
            yearToDateTax: TaxMoney(amount: input.realizedTax + dividendTax, currency: currency),
            projectedYearEndTax: TaxMoney(amount: projectedTax, currency: currency),
            annualTaxDrag: TaxMoney(amount: projectedTax, currency: currency),
            taxCostRatio: ratio,
            components: [
                TaxDragComponent(
                    id: "realized-capital-gains",
                    label: "Realized capital gains",
                    yearToDate: TaxMoney(amount: input.realizedTax, currency: currency),
                    projectedYearEnd: TaxMoney(amount: projectedRealized, currency: currency),
                    dataQuality: .verified
                ),
                TaxDragComponent(
                    id: "investment-income",
                    label: "Dividends and distributions",
                    yearToDate: TaxMoney(amount: dividendTax, currency: currency),
                    projectedYearEnd: TaxMoney(amount: projectedIncome, currency: currency),
                    dataQuality: dividends.isEmpty ? .incomplete : .estimated
                ),
                TaxDragComponent(
                    id: "embedded-liability",
                    label: "Embedded unrealized liability",
                    yearToDate: TaxMoney(amount: input.embeddedLiability, currency: currency),
                    projectedYearEnd: TaxMoney(amount: input.embeddedLiability, currency: currency),
                    dataQuality: .estimated
                ),
            ]
        )
    }

    private func yearInterval(_ taxYear: Int) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: taxYear, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: taxYear + 1, month: 1, day: 1))!
        return (start, end)
    }

    private func annualizationFactor(taxYear: Int, start: Date) -> Decimal {
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        guard taxYear == currentYear else { return taxYear < currentYear ? 1 : 0 }
        let elapsed = max(1, Calendar(identifier: .gregorian).dateComponents([.day], from: start, to: Date()).day ?? 1)
        return min(4, Decimal(365) / Decimal(elapsed))
    }
}

struct TaxAssetLocationEngine: Sendable {
    private struct PositionedAsset: Sendable {
        let account: Account
        let position: Position
        let instrument: Instrument
        let value: Decimal
        let annualTaxCostRate: Decimal
    }

    func opportunities(
        accounts: [Account],
        positions: [Position],
        instrumentsByID: [UUID: Instrument],
        openLots: [Lot],
        profile: TaxProfileRequest,
        pack: ConfiguredTaxRulePack,
        catalog: TaxOptimizationCatalog
    ) -> [TaxLocationOpportunity] {
        let accountByID = Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
            account.id.map { ($0, account) }
        })
        let assets = positions.compactMap { position -> PositionedAsset? in
            guard let account = accountByID[position.accountId],
                  let instrument = instrumentsByID[position.instrumentId],
                  let entry = catalog.efficiencyEntry(for: instrument.instrumentType ?? "stock")
            else { return nil }
            let value = Decimal(max(0, position.quantity * (position.lastPrice ?? position.averageCost)))
            guard value > 0 else { return nil }
            return PositionedAsset(
                account: account,
                position: position,
                instrument: instrument,
                value: value,
                annualTaxCostRate: annualTaxCostRate(entry: entry, profile: profile, pack: pack)
            )
        }
        let taxable = assets.filter {
            TaxAccountWrapper(rawValue: $0.account.taxWrapper ?? "") == .taxable
        }.sorted { $0.annualTaxCostRate > $1.annualTaxCostRate }
        let advantaged = assets.filter {
            let wrapper = TaxAccountWrapper(rawValue: $0.account.taxWrapper ?? "") ?? .unknown
            return wrapper != .taxable && wrapper != .unknown
        }.sorted { $0.annualTaxCostRate < $1.annualTaxCostRate }
        guard let highDrag = taxable.first, let lowDrag = advantaged.first,
              let highAccountID = highDrag.account.id,
              let lowAccountID = lowDrag.account.id,
              let highInstrumentID = highDrag.instrument.id,
              let lowInstrumentID = lowDrag.instrument.id,
              highDrag.position.currency.uppercased() == lowDrag.position.currency.uppercased()
        else { return [] }

        let notional = min(highDrag.value, lowDrag.value)
        let annualSavings = max(0, (highDrag.annualTaxCostRate - lowDrag.annualTaxCostRate) * notional)
        guard annualSavings > 0 else { return [] }
        let immediateTaxCost = realizedTaxCost(
            asset: highDrag,
            notional: notional,
            lots: openLots,
            profile: profile,
            pack: pack
        )
        let breakEvenMonths = immediateTaxCost > 0
            ? Int(NSDecimalNumber(decimal: immediateTaxCost / annualSavings * 12).doubleValue.rounded(.up))
            : 0
        let currency = profile.reportingCurrency
        let support: TaxSupportLevel = pack.isValidated ? .supported : .estimateOnly
        let legs: [TaxLocationLeg]
        var warnings = [String]()
        if breakEvenMonths <= 36 {
            legs = [
                leg(account: highAccountID, instrument: highInstrumentID, symbol: highDrag.instrument.symbol, side: .sell, notional: notional, currency: currency),
                leg(account: lowAccountID, instrument: highInstrumentID, symbol: highDrag.instrument.symbol, side: .buy, notional: notional, currency: currency),
                leg(account: lowAccountID, instrument: lowInstrumentID, symbol: lowDrag.instrument.symbol, side: .sell, notional: notional, currency: currency),
                leg(account: highAccountID, instrument: lowInstrumentID, symbol: lowDrag.instrument.symbol, side: .buy, notional: notional, currency: currency),
            ]
        } else {
            legs = [leg(
                account: lowAccountID,
                instrument: highInstrumentID,
                symbol: highDrag.instrument.symbol,
                side: .futureContribution,
                notional: notional,
                currency: currency
            )]
            warnings.append("The estimated realization cost exceeds a 36-month break-even; direct future contributions are preferred.")
        }
        if support != .supported {
            warnings.append("Asset-location savings are estimate-only until this jurisdiction's rule pack is validated.")
        }
        return [TaxLocationOpportunity(
            id: "location:\(highInstrumentID.uuidString):\(lowInstrumentID.uuidString):\(highAccountID.uuidString):\(lowAccountID.uuidString)",
            supportLevel: support,
            title: "Improve the location of \(highDrag.instrument.symbol)",
            annualSavings: TaxMoney(amount: annualSavings, currency: currency),
            immediateTaxCost: TaxMoney(amount: immediateTaxCost, currency: currency),
            breakEvenMonths: breakEvenMonths,
            confidence: support == .supported ? Decimal(string: "0.85")! : Decimal(string: "0.55")!,
            legs: legs,
            warnings: warnings
        )]
    }

    private func annualTaxCostRate(
        entry: TaxEfficiencyCatalogEntry,
        profile: TaxProfileRequest,
        pack: ConfiguredTaxRulePack
    ) -> Decimal {
        let ordinaryRate = profile.marginalIncomeTaxRate
            ?? profile.shortTermCapitalGainsRate
            ?? pack.rate(isLongTerm: false, profile: profile)
            ?? 0
        let capitalRate = profile.longTermCapitalGainsRate
            ?? pack.rate(isLongTerm: true, profile: profile)
            ?? ordinaryRate
        let incomeRate = entry.ordinaryIncomeShare * ordinaryRate
            + (1 - entry.ordinaryIncomeShare) * capitalRate
        return entry.expectedYield * incomeRate + entry.turnover * capitalRate
    }

    private func realizedTaxCost(
        asset: PositionedAsset,
        notional: Decimal,
        lots: [Lot],
        profile: TaxProfileRequest,
        pack: ConfiguredTaxRulePack
    ) -> Decimal {
        let price = asset.position.lastPrice ?? asset.position.averageCost
        guard price > 0 else { return 0 }
        let quantity = min(Decimal(asset.position.quantity), notional / Decimal(price))
        var remaining = quantity
        var taxableGain = Decimal.zero
        for lot in lots
            .filter({ $0.accountId == asset.position.accountId && $0.instrumentId == asset.position.instrumentId })
            .sorted(by: { $0.openDate < $1.openDate }) where remaining > 0
        {
            let sold = min(remaining, Decimal(lot.remainingQuantity))
            let gain = sold * (Decimal(price) - Decimal(lot.openPrice))
            if gain > 0 {
                let isLongTerm = Date().timeIntervalSince(lot.openDate) > 365 * 86400
                taxableGain += gain * (pack.rate(isLongTerm: isLongTerm, profile: profile) ?? 0)
            }
            remaining -= sold
        }
        return max(0, taxableGain)
    }

    private func leg(
        account: UUID,
        instrument: UUID,
        symbol: String,
        side: TaxLocationLegSide,
        notional: Decimal,
        currency: String
    ) -> TaxLocationLeg {
        TaxLocationLeg(
            id: UUID().uuidString,
            accountId: account.uuidString,
            instrumentId: instrument.uuidString,
            symbol: symbol,
            side: side,
            notional: TaxMoney(amount: notional, currency: currency)
        )
    }
}

struct TaxGoalImpactCalculator: Sendable {
    func impacts(
        userId: UUID,
        affectedPortfolioIDs: Set<UUID>,
        benefit: Decimal,
        currency: String,
        on database: any Database
    ) async throws -> [TaxGoalImpact] {
        guard benefit > 0, !affectedPortfolioIDs.isEmpty else { return [] }
        let allocations = try await GoalPortfolioAllocationModel.query(on: database)
            .filter(\.$userId == userId)
            .filter(\.$portfolioListId ~~ Array(affectedPortfolioIDs))
            .all()
        let allocationByGoal = Dictionary(grouping: allocations, by: { $0.$goal.id })
        let goalIDs = Array(allocationByGoal.keys)
        let goals = goalIDs.isEmpty ? [] : try await FinancialGoalModel.query(on: database)
            .filter(\.$id ~~ goalIDs)
            .filter(\.$userId == userId)
            .filter(\.$status == FinancialGoalStatus.active.rawValue)
            .all()
        let snapshots = goalIDs.isEmpty ? [] : try await GoalProgressSnapshotModel.query(on: database)
            .filter(\.$userId == userId)
            .filter(\.$goal.$id ~~ goalIDs)
            .sort(\.$calculatedAt, .descending)
            .all()
        let latestSnapshot = Dictionary(grouping: snapshots, by: { $0.$goal.id }).compactMapValues { $0.first }
        return goals.compactMap { goal -> TaxGoalImpact? in
            guard let goalID = goal.id else { return nil }
            let allocation = (allocationByGoal[goalID] ?? []).reduce(0) {
                $0 + $1.allocationPercentage / 100
            }
            let applied = benefit * Decimal(min(1, max(0, allocation)))
            let principal = latestSnapshot[goalID]?.currentValue ?? goal.startingCapital
            let baselineMonths = GoalProjectionCalculator.monthsToTarget(
                principal: principal,
                target: goal.targetAmount,
                monthlyContribution: goal.monthlyContribution,
                annualRate: goal.expectedAnnualReturn
            )
            let improvedMonths = GoalProjectionCalculator.monthsToTarget(
                principal: principal + NSDecimalNumber(decimal: applied).doubleValue,
                target: goal.targetAmount,
                monthlyContribution: goal.monthlyContribution,
                annualRate: goal.expectedAnnualReturn
            )
            return TaxGoalImpact(
                goalId: goalID.uuidString,
                goalName: goal.name,
                currency: currency,
                benefitApplied: applied,
                baselineCompletionDate: completionDate(months: baselineMonths),
                projectedCompletionDate: completionDate(months: improvedMonths),
                monthsSooner: monthsSooner(baseline: baselineMonths, improved: improvedMonths),
                assumption: "Assumes the after-cost tax benefit is immediately reinvested and earns the goal's configured return."
            )
        }
    }

    private func completionDate(months: Int?) -> String? {
        guard let months, let date = Calendar(identifier: .gregorian).date(byAdding: .month, value: months, to: Date()) else {
            return nil
        }
        return isoDate(date)
    }

    private func monthsSooner(baseline: Int?, improved: Int?) -> Int? {
        guard let baseline, let improved else { return nil }
        return max(0, baseline - improved)
    }
}
