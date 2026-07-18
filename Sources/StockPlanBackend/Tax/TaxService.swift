import Crypto
import Fluent
import Foundation
import StockPlanShared
import Vapor

private let taxDisclaimer = "Educational estimate only. Review all calculations and transactions with a qualified tax professional before acting or filing."

protocol TaxService: Sendable {
    func capabilities(taxYear: Int) -> TaxCapabilitiesResponse
    func profileContext(userId: UUID, jurisdiction: TaxJurisdiction, taxYear: Int, on db: any Database) async throws -> TaxProfileContextResponse
    func profile(userId: UUID, jurisdiction: TaxJurisdiction, taxYear: Int, on db: any Database) async throws -> TaxProfileResponse?
    func saveProfile(userId: UUID, request: TaxProfileRequest, on db: any Database) async throws -> TaxProfileResponse
    func dashboard(userId: UUID, jurisdiction: TaxJurisdiction, taxYear: Int, on db: any Database) async throws -> TaxDashboardResponse
    func createScenario(userId: UUID, request: TaxScenarioRequest, jurisdiction: TaxJurisdiction, on db: any Database) async throws -> TaxScenarioResponse
    func scenario(userId: UUID, id: UUID, on db: any Database) async throws -> TaxScenarioResponse?
    func createActionPlan(userId: UUID, request: TaxActionPlanRequest, on db: any Database) async throws -> TaxActionPlanResponse
    func actionPlans(userId: UUID, on db: any Database) async throws -> [TaxActionPlanResponse]
    func actionPlan(userId: UUID, id: UUID, on db: any Database) async throws -> TaxActionPlanResponse?
    func transitionActionPlan(userId: UUID, id: UUID, request: TaxActionPlanTransitionRequest, on db: any Database) async throws -> TaxActionPlanResponse
    func createLocationScenario(userId: UUID, request: TaxLocationScenarioRequest, jurisdiction: TaxJurisdiction, on db: any Database) async throws -> TaxLocationScenarioResponse
    func createPlacementPlan(userId: UUID, request: TaxPlacementPlanRequest, on db: any Database) async throws -> TaxActionPlanResponse
    func dismissOpportunity(userId: UUID, opportunityId: String, jurisdiction: TaxJurisdiction, taxYear: Int, on db: any Database) async throws
    func restoreOpportunity(userId: UUID, opportunityId: String, taxYear: Int, on db: any Database) async throws
    func notificationPreferences(userId: UUID, on db: any Database) async throws -> TaxNotificationPreferences
    func saveNotificationPreferences(userId: UUID, request: TaxNotificationPreferences, on db: any Database) async throws -> TaxNotificationPreferences
    func saveMarketAdmission(userId: UUID, instrumentId: UUID, status: TaxMarketAdmissionStatus, on db: any Database) async throws -> TaxInstrumentMarketOption
    func saveFundClassification(userId: UUID, instrumentId: UUID, classification: TaxFundClassification, on db: any Database) async throws -> TaxInstrumentMarketOption
}

struct DefaultTaxService: TaxService {
    let rules: TaxRuleRegistry
    let catalog: TaxOptimizationCatalog
    let isV2Enabled: Bool

    func capabilities(taxYear: Int) -> TaxCapabilitiesResponse {
        TaxCapabilitiesResponse(generatedAt: isoDate(Date()), capabilities: rules.capabilities(taxYear: taxYear))
    }

    func profileContext(
        userId: UUID,
        jurisdiction: TaxJurisdiction,
        taxYear: Int,
        on db: any Database
    ) async throws -> TaxProfileContextResponse {
        let existing = try await profile(userId: userId, jurisdiction: jurisdiction, taxYear: taxYear, on: db)
        let ownedAccounts = try await Account.query(on: db)
            .filter(\.$userId == userId)
            .all()
        let accounts = ownedAccounts
            .compactMap { account -> TaxProfileAccountOption? in
                guard let id = account.id else { return nil }
                let broker = account.broker.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedDisplayName = account.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                return TaxProfileAccountOption(
                    id: id.uuidString,
                    displayName: trimmedDisplayName?.isEmpty == false
                        ? trimmedDisplayName!
                        : (broker.isEmpty ? "Investment account" : broker.uppercased()),
                    broker: broker,
                    baseCurrency: account.baseCurrency.uppercased(),
                    wrapper: account.taxWrapper.flatMap(TaxAccountWrapper.init(rawValue:)) ?? .unknown,
                    ownerMemberId: account.taxOwnerMemberId,
                    lotSelectionMethod: account.lotSelectionMethod.flatMap(TaxLotSelectionMethod.init(rawValue:)) ?? .jurisdictionDefault
                )
            }
            .sorted {
                let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
        let accountIDs = ownedAccounts.compactMap(\.id)
        let transactionInstrumentIDs = accountIDs.isEmpty ? [] : try await Transaction.query(on: db)
            .filter(\.$accountId ~~ accountIDs)
            .all()
            .map(\.instrumentId)
        let ownedLots = accountIDs.isEmpty ? [] : try await Lot.query(on: db)
            .filter(\.$accountId ~~ accountIDs)
            .all()
        let lotInstrumentIDs = ownedLots.map(\.instrumentId)
        let instrumentIDs = Array(Set(transactionInstrumentIDs + lotInstrumentIDs))
        let instruments = instrumentIDs.isEmpty ? [] : try await Instrument.query(on: db)
            .filter(\.$id ~~ instrumentIDs)
            .all()
            .compactMap(taxInstrumentMarketOption)
            .sorted {
                ($0.symbol, $0.id) < ($1.symbol, $1.id)
            }
        let fundInstrumentIDs = try await Set(Instrument.query(on: db)
            .filter(\.$id ~~ instrumentIDs)
            .all()
            .compactMap { instrument -> UUID? in
                guard let id = instrument.id,
                      ["etf", "fund", "mutual_fund"].contains(instrument.instrumentType?.lowercased() ?? "")
                else { return nil }
                return id
            })
        let fundLots = ownedLots.compactMap { lot -> TaxFundLotOption? in
            guard let id = lot.id, fundInstrumentIDs.contains(lot.instrumentId) else { return nil }
            return TaxFundLotOption(
                id: id.uuidString,
                accountId: lot.accountId.uuidString,
                instrumentId: lot.instrumentId.uuidString,
                openedAt: isoDate(lot.openDate),
                originalQuantity: Decimal(lot.openQuantity),
                remainingQuantity: Decimal(lot.remainingQuantity)
            )
        }.sorted { ($0.openedAt, $0.id) < ($1.openedAt, $1.id) }
        return TaxProfileContextResponse(
            jurisdiction: jurisdiction,
            taxYear: taxYear,
            defaultReportingCurrency: defaultCurrency(jurisdiction),
            profile: existing,
            accounts: accounts,
            instruments: instruments,
            fundLots: fundLots
        )
    }

    func saveMarketAdmission(
        userId: UUID,
        instrumentId: UUID,
        status: TaxMarketAdmissionStatus,
        on db: any Database
    ) async throws -> TaxInstrumentMarketOption {
        let accountIDs = try await Account.query(on: db)
            .filter(\.$userId == userId)
            .all()
            .compactMap(\.id)
        guard !accountIDs.isEmpty else { throw Abort(.notFound, reason: "Instrument not found.") }
        let ownsTransaction = try await Transaction.query(on: db)
            .filter(\.$accountId ~~ accountIDs)
            .filter(\.$instrumentId == instrumentId)
            .first() != nil
        let ownsLot = try await Lot.query(on: db)
            .filter(\.$accountId ~~ accountIDs)
            .filter(\.$instrumentId == instrumentId)
            .first() != nil
        guard ownsTransaction || ownsLot,
              let instrument = try await Instrument.find(instrumentId, on: db)
        else { throw Abort(.notFound, reason: "Instrument not found.") }
        instrument.regulatedMarketStatus = status.rawValue
        instrument.regulatedMarketSource = status == .unknown ? nil : "user_verified_document"
        instrument.regulatedMarketReviewedAt = status == .unknown ? nil : Date()
        try await instrument.save(on: db)
        return taxInstrumentMarketOption(instrument)!
    }

    func saveFundClassification(
        userId: UUID,
        instrumentId: UUID,
        classification: TaxFundClassification,
        on db: any Database
    ) async throws -> TaxInstrumentMarketOption {
        let accountIDs = try await Account.query(on: db)
            .filter(\.$userId == userId)
            .all()
            .compactMap(\.id)
        guard !accountIDs.isEmpty else { throw Abort(.notFound, reason: "Instrument not found.") }
        let ownsTransaction = try await Transaction.query(on: db)
            .filter(\.$accountId ~~ accountIDs)
            .filter(\.$instrumentId == instrumentId)
            .first() != nil
        let ownsLot = try await Lot.query(on: db)
            .filter(\.$accountId ~~ accountIDs)
            .filter(\.$instrumentId == instrumentId)
            .first() != nil
        guard ownsTransaction || ownsLot,
              let instrument = try await Instrument.find(instrumentId, on: db)
        else { throw Abort(.notFound, reason: "Instrument not found.") }
        instrument.fundClassification = classification.rawValue
        try await instrument.save(on: db)
        return taxInstrumentMarketOption(instrument)!
    }

    func profile(
        userId: UUID,
        jurisdiction: TaxJurisdiction,
        taxYear: Int,
        on db: any Database
    ) async throws -> TaxProfileResponse? {
        guard let model = try await TaxProfile.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$jurisdiction == jurisdiction.rawValue)
            .filter(\.$taxYear == taxYear)
            .first()
        else { return nil }
        return try profileResponse(model)
    }

    func saveProfile(userId: UUID, request: TaxProfileRequest, on db: any Database) async throws -> TaxProfileResponse {
        let memberIDs = Set(request.members.map(\.id))
        guard memberIDs.count == request.members.count,
              request.accounts.allSatisfy({ memberIDs.contains($0.ownerMemberId) }),
              Set(request.accounts.map(\.accountId)).count == request.accounts.count
        else { throw Abort(.unprocessableEntity, reason: "Tax household and account classifications are invalid.") }
        let requestedAccountIDs = try request.accounts.map { classification -> UUID in
            guard let id = UUID(uuidString: classification.accountId) else {
                throw Abort(.unprocessableEntity, reason: "A tax account identifier is invalid.")
            }
            return id
        }
        let ownedAccounts = requestedAccountIDs.isEmpty ? [] : try await Account.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$id ~~ requestedAccountIDs)
            .all()
        guard ownedAccounts.count == requestedAccountIDs.count else {
            throw Abort(.unprocessableEntity, reason: "One or more tax accounts do not belong to this user.")
        }
        let missing = missingFields(request)
        let model = try await TaxProfile.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$jurisdiction == request.jurisdiction.rawValue)
            .filter(\.$taxYear == request.taxYear)
            .first() ?? TaxProfile()
        model.userId = userId
        model.jurisdiction = request.jurisdiction.rawValue
        model.taxYear = request.taxYear
        model.filingStatus = request.filingStatus.rawValue
        model.reportingCurrency = request.reportingCurrency.uppercased()
        model.profileJSON = try encode(request)
        model.isComplete = missing.isEmpty
        try await model.save(on: db)

        let ownedByID = Dictionary(uniqueKeysWithValues: ownedAccounts.compactMap { account in account.id.map { ($0, account) } })
        for account in request.accounts {
            guard let accountID = UUID(uuidString: account.accountId), let owned = ownedByID[accountID] else { continue }
            owned.taxWrapper = account.wrapper.rawValue
            owned.taxJurisdiction = request.jurisdiction.rawValue
            owned.taxOwnerMemberId = account.ownerMemberId
            owned.lotSelectionMethod = account.lotSelectionMethod.rawValue
            try await owned.save(on: db)
        }
        return try profileResponse(model)
    }

    func dashboard(
        userId: UUID,
        jurisdiction: TaxJurisdiction,
        taxYear: Int,
        on db: any Database
    ) async throws -> TaxDashboardResponse {
        guard let profileModel = try await TaxProfile.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$jurisdiction == jurisdiction.rawValue)
            .filter(\.$taxYear == taxYear)
            .first()
        else {
            return emptyDashboard(jurisdiction: jurisdiction, taxYear: taxYear, currency: defaultCurrency(jurisdiction))
        }

        let profile = try decode(TaxProfileRequest.self, from: profileModel.profileJSON)
        let pack = rules.pack(for: jurisdiction)
        let accounts = try await Account.query(on: db).filter(\.$userId == userId).all()
        let accountIDs = accounts.compactMap(\.id)
        let lots = accountIDs.isEmpty ? [] : try await Lot.query(on: db)
            .filter(\.$accountId ~~ accountIDs)
            .filter(\.$status == "open")
            .all()
        let lotIDs = lots.compactMap(\.id)
        let adjustments = lotIDs.isEmpty ? [] : try await LotAdjustment.query(on: db)
            .filter(\.$lotId ~~ lotIDs)
            .all()
        let adjustmentByLot = Dictionary(grouping: adjustments, by: \.lotId)
            .mapValues { values in values.reduce(0) { $0 + $1.amount } }
        let decisions = try await TaxOpportunityDecision.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$taxYear == taxYear)
            .all()
        let decisionByOpportunity = Dictionary(uniqueKeysWithValues: decisions.map { ($0.opportunityId, $0) })
        let positions = accountIDs.isEmpty ? [] : try await Position.query(on: db)
            .filter(\.$accountId ~~ accountIDs)
            .all()
        let instrumentIDs = Set(lots.map(\.instrumentId) + positions.map(\.instrumentId))
        let instruments = instrumentIDs.isEmpty ? [] : try await Instrument.query(on: db)
            .filter(\.$id ~~ Array(instrumentIDs))
            .all()
        let instrumentsByID = Dictionary(uniqueKeysWithValues: instruments.compactMap { instrument in
            instrument.id.map { ($0, instrument) }
        })
        let positionsByKey = Dictionary(uniqueKeysWithValues: positions.map {
            (positionKey(account: $0.accountId, instrument: $0.instrumentId), $0)
        })
        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
            account.id.map { ($0, account) }
        })

        var opportunities = [TaxOpportunityResponse]()
        var embeddedLiability = Decimal.zero
        var harvestableLosses = Decimal.zero
        var estimatedBenefit = Decimal.zero
        var unsupportedValue = Decimal.zero
        let now = Date()

        for lot in lots where lot.remainingQuantity > 0 {
            guard let instrument = instrumentsByID[lot.instrumentId],
                  let account = accountsByID[lot.accountId]
            else { continue }
            let wrapper = TaxAccountWrapper(rawValue: account.taxWrapper ?? "") ?? .unknown
            let instrumentType = instrument.instrumentType ?? "stock"
            var support = pack.supportLevel(instrumentType: instrumentType, wrapper: wrapper)
            let position = positionsByKey[positionKey(account: lot.accountId, instrument: lot.instrumentId)]
            let priceQuality = taxPriceQuality(position: position, now: now)
            let price = position?.lastPrice ?? position.map(\.averageCost) ?? lot.openPrice
            let marketValue = Decimal(price * lot.remainingQuantity)
            let basis = Decimal(lot.openPrice * lot.remainingQuantity + (lot.id.flatMap { adjustmentByLot[$0] } ?? 0))
            let gain = marketValue - basis
            var taxableGain = gain
            let normalizedType = instrumentType.lowercased()
            let isGermanFund = pack.jurisdiction == .germany
                && ["etf", "fund", "mutual_fund"].contains(normalizedType)
            if isGermanFund {
                if let classification = instrument.fundClassification.flatMap(TaxFundClassification.init(rawValue:)),
                   let adjusted = GermanyFundPartialExemptionCalculator.taxableAmount(
                       gain,
                       classification: classification
                   )
                {
                    taxableGain = adjusted
                    support = .estimateOnly
                } else {
                    support = .professionalReview
                }
            }
            let isLongTerm = now.timeIntervalSince(lot.openDate) > 365 * 86400

            guard support == .supported || support == .estimateOnly else {
                unsupportedValue += marketValue
                continue
            }
            guard let rate = pack.rate(isLongTerm: isLongTerm, profile: profile) else {
                unsupportedValue += marketValue
                continue
            }
            if gain >= 0 {
                embeddedLiability += taxableGain * rate
                continue
            }

            let loss = -gain
            let benefit = max(0, -taxableGain) * rate
            let recentReplacement = try await hasRecentReplacement(
                userId: userId,
                instrument: instrument,
                since: Calendar.current.date(byAdding: .day, value: -30, to: now)!,
                excludingTransactionId: lot.openTransactionId,
                on: db
            )
            let actionable = support == .supported
                && !recentReplacement
                && profileModel.isComplete
                && priceQuality == .fresh
            let transactionCosts = marketValue * Decimal(string: "0.001")!
            let afterCostBenefit = max(0, benefit - transactionCosts)
            let opportunityID = lot.id!.uuidString
            let decision = decisionByOpportunity[opportunityID]
            let materiallyImproved = decision.map {
                afterCostBenefit >= Decimal($0.estimatedBenefit) * Decimal(string: "1.25")!
            } ?? false
            let status: TaxOpportunityStatus = if decision?.status == TaxOpportunityStatus.dismissed.rawValue,
                                                  !materiallyImproved
            {
                .dismissed
            } else if decision?.status == TaxOpportunityStatus.accepted.rawValue {
                .accepted
            } else if actionable {
                .actionable
            } else if recentReplacement {
                .blocked
            } else {
                .watch
            }
            var warnings = [String]()
            if recentReplacement {
                warnings.append("A substantially identical acquisition was detected in the prior 30 days. Review wash-sale treatment.")
            }
            if support != .supported {
                warnings.append("This rule pack is estimate-only until professional validation is enabled.")
            }
            if isGermanFund {
                warnings.append("The estimate applies the configured German fund partial exemption to both gains and losses.")
            }
            if priceQuality != .fresh {
                warnings.append("A fresh market price is required before this opportunity can become actionable.")
            }
            let replacements = isV2Enabled
                ? try await TaxReplacementService(catalog: catalog).candidates(for: instrument, jurisdiction: jurisdiction, on: db)
                : []
            let effectiveStatus: TaxOpportunityStatus = status == .actionable && isV2Enabled && replacements.isEmpty
                ? .watch
                : status
            if isV2Enabled, replacements.isEmpty {
                warnings.append("No advisor-reviewed replacement is available in catalog \(catalog.replacements.version).")
            }
            let lotDetail = TaxLotDetail(
                id: opportunityID,
                openedAt: isoDate(lot.openDate),
                eligibleQuantity: Decimal(lot.remainingQuantity),
                unitBasis: TaxMoney(amount: Decimal(lot.openPrice), currency: lot.currency),
                adjustedBasis: TaxMoney(amount: basis, currency: lot.currency),
                marketValue: TaxMoney(amount: marketValue, currency: profile.reportingCurrency),
                unrealizedGainLoss: TaxMoney(amount: gain, currency: profile.reportingCurrency),
                holdingPeriod: isLongTerm ? "long_term" : "short_term",
                dataQuality: priceQuality == .fresh ? .verified : .estimated
            )
            opportunities.append(TaxOpportunityResponse(
                id: opportunityID,
                accountId: lot.accountId.uuidString,
                instrumentId: lot.instrumentId.uuidString,
                symbol: instrument.symbol,
                instrumentType: instrumentType,
                status: effectiveStatus,
                supportLevel: support,
                marketValue: TaxMoney(amount: marketValue, currency: profile.reportingCurrency),
                unrealizedLoss: TaxMoney(amount: loss, currency: profile.reportingCurrency),
                estimatedTaxBenefit: TaxMoney(amount: benefit, currency: profile.reportingCurrency),
                eligibleQuantity: Decimal(lot.remainingQuantity),
                holdingPeriod: isLongTerm ? "long_term" : "short_term",
                washSaleWindowEndsAt: recentReplacement ? isoDate(Calendar.current.date(byAdding: .day, value: 31, to: now)!) : nil,
                warnings: warnings,
                confidence: support == .supported && priceQuality == .fresh
                    ? Decimal(string: "0.95")!
                    : Decimal(string: "0.50")!,
                portfolioId: account.portfolioId?.uuidString,
                priceQuality: priceQuality,
                pricedAt: position?.lastPriceDate.map(isoDate),
                lots: [lotDetail],
                replacementCandidates: replacements,
                currentYearTaxReduction: TaxMoney(amount: benefit, currency: profile.reportingCurrency),
                deferredTaxLiability: TaxMoney(amount: benefit, currency: profile.reportingCurrency),
                estimatedTransactionCosts: TaxMoney(amount: transactionCosts, currency: profile.reportingCurrency),
                estimatedAfterCostBenefit: TaxMoney(amount: afterCostBenefit, currency: profile.reportingCurrency)
            ))
            harvestableLosses += loss
            if effectiveStatus == .actionable {
                estimatedBenefit += afterCostBenefit
            }
        }

        let realized = try await realizedLiability(
            accountIDs: accountIDs,
            taxYear: taxYear,
            profile: profile,
            pack: pack,
            on: db
        )
        let taxDrag = isV2Enabled ? try await TaxDragAnalytics().projection(
            input: .init(
                accountIDs: accountIDs,
                taxYear: taxYear,
                profile: profile,
                pack: pack,
                realizedTax: realized,
                embeddedLiability: embeddedLiability,
                positions: positions
            ),
            on: db
        ) : nil
        let locationOpportunities = isV2Enabled ? TaxAssetLocationEngine().opportunities(
            accounts: accounts,
            positions: positions,
            instrumentsByID: instrumentsByID,
            openLots: lots,
            profile: profile,
            pack: pack,
            catalog: catalog
        ) : []
        opportunities.sort { $0.estimatedTaxBenefit.amount > $1.estimatedTaxBenefit.amount }
        let currency = profile.reportingCurrency
        let summary = TaxProjectionSummary(
            realizedEstimatedLiability: TaxMoney(amount: realized, currency: currency),
            embeddedUnrealizedLiability: TaxMoney(amount: embeddedLiability, currency: currency),
            harvestableLosses: TaxMoney(amount: harvestableLosses, currency: currency),
            estimatedNetBenefit: TaxMoney(amount: estimatedBenefit, currency: currency),
            shortTermCarryover: TaxMoney(amount: profile.priorShortTermLossCarryover, currency: currency),
            longTermCarryover: TaxMoney(amount: profile.priorLongTermLossCarryover, currency: currency),
            taxCostRatio: taxDrag?.taxCostRatio
        )
        let response = TaxDashboardResponse(
            generatedAt: isoDate(now),
            taxYear: taxYear,
            jurisdiction: jurisdiction,
            ruleVersion: pack.ruleVersion,
            isStale: false,
            profileComplete: profileModel.isComplete,
            summary: summary,
            opportunities: opportunities,
            unsupportedValue: TaxMoney(amount: unsupportedValue, currency: currency),
            assumptions: pack.assumptions(taxYear: taxYear),
            disclaimer: taxDisclaimer,
            catalogVersion: isV2Enabled ? catalog.replacements.version : nil,
            taxDrag: taxDrag,
            locationOpportunities: isV2Enabled ? locationOpportunities : nil
        )
        try await storeSnapshot(response, userId: userId, profileId: profileModel.id!, on: db)
        return response
    }

    func createScenario(
        userId: UUID,
        request: TaxScenarioRequest,
        jurisdiction: TaxJurisdiction,
        on db: any Database
    ) async throws -> TaxScenarioResponse {
        let dashboard = try await dashboard(userId: userId, jurisdiction: jurisdiction, taxYear: request.taxYear, on: db)
        let requested = Set(request.opportunityIds)
        let selected = dashboard.opportunities.filter { requested.contains($0.id) }
        guard !selected.isEmpty else { throw Abort(.unprocessableEntity, reason: "Select at least one available tax opportunity.") }
        var selectedReplacements = [String: TaxReplacementCandidate]()
        for opportunity in selected {
            let available = opportunity.replacementCandidates ?? []
            guard !available.isEmpty else { continue }
            guard let requestedReplacementID = request.plannedReplacementInstrumentIds[opportunity.id],
                  let replacement = available.first(where: { $0.instrumentId == requestedReplacementID })
            else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Choose an advisor-reviewed replacement for \(opportunity.symbol)."
                )
            }
            selectedReplacements[opportunity.id] = replacement
        }
        let benefit = selected.reduce(Decimal.zero) {
            $0 + ($1.currentYearTaxReduction?.amount ?? $1.estimatedTaxBenefit.amount)
        }
        let losses = selected.reduce(Decimal.zero) { $0 + $1.unrealizedLoss.amount }
        let currency = dashboard.summary.estimatedNetBenefit.currency
        let baselineTax = dashboard.summary.realizedEstimatedLiability.amount
            + dashboard.summary.embeddedUnrealizedLiability.amount
        let fees = selected.reduce(Decimal.zero) { partial, item in
            partial + (item.estimatedTransactionCosts?.amount
                ?? item.marketValue.amount * Decimal(string: "0.001")!)
        }
        let deferredLiability = selected.reduce(Decimal.zero) {
            $0 + ($1.deferredTaxLiability?.amount ?? 0)
        }
        let affectedPortfolioIDs = Set(selected.compactMap { item in
            item.portfolioId.flatMap(UUID.init(uuidString:))
        })
        let goalImpacts = try await TaxGoalImpactCalculator().impacts(
            userId: userId,
            affectedPortfolioIDs: affectedPortfolioIDs,
            benefit: max(0, benefit - fees),
            currency: currency,
            on: db
        )
        let allocationImpacts = try await TaxAllocationImpactCalculator().impacts(
            userId: userId,
            opportunities: selected,
            replacements: selectedReplacements,
            on: db
        )
        let responseID = UUID()
        let response = TaxScenarioResponse(
            id: responseID.uuidString,
            createdAt: isoDate(Date()),
            baseline: TaxScenarioColumn(
                currentYearTax: TaxMoney(amount: baselineTax, currency: currency),
                nextYearTax: TaxMoney(amount: dashboard.summary.embeddedUnrealizedLiability.amount, currency: currency),
                realizedLosses: TaxMoney(amount: 0, currency: currency),
                carryover: TaxMoney(amount: dashboard.summary.shortTermCarryover.amount + dashboard.summary.longTermCarryover.amount, currency: currency),
                feesAndSpread: TaxMoney(amount: 0, currency: currency)
            ),
            harvestNow: TaxScenarioColumn(
                currentYearTax: TaxMoney(amount: max(0, baselineTax - benefit), currency: currency),
                nextYearTax: TaxMoney(amount: dashboard.summary.embeddedUnrealizedLiability.amount, currency: currency),
                realizedLosses: TaxMoney(amount: losses, currency: currency),
                carryover: TaxMoney(amount: max(0, losses - baselineTax), currency: currency),
                feesAndSpread: TaxMoney(amount: fees, currency: currency)
            ),
            estimatedNetBenefit: TaxMoney(amount: max(0, benefit - fees), currency: currency),
            warnings: selected.flatMap(\.warnings),
            assumptions: dashboard.assumptions + [
                "Allocation impacts use current same-currency position values and assume replacement purchases equal each proposed sale notional.",
            ],
            currentYearTaxReduction: TaxMoney(amount: benefit, currency: currency),
            deferredTaxLiability: TaxMoney(amount: deferredLiability, currency: currency),
            estimatedTransactionCosts: TaxMoney(amount: fees, currency: currency),
            goalImpacts: goalImpacts,
            selectedReplacements: selectedReplacements,
            allocationImpacts: allocationImpacts
        )
        guard let profile = try await TaxProfile.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$jurisdiction == jurisdiction.rawValue)
            .filter(\.$taxYear == request.taxYear)
            .first()
        else { throw Abort(.unprocessableEntity, reason: "Complete a tax profile first.") }
        let model = TaxScenario()
        model.id = responseID
        model.userId = userId
        model.profileId = profile.id!
        model.kind = TaxActionPlanKind.harvest.rawValue
        model.requestJSON = try encode(request)
        model.responseJSON = try encode(response)
        try await model.create(on: db)
        return response
    }

    func scenario(userId: UUID, id: UUID, on db: any Database) async throws -> TaxScenarioResponse? {
        guard let model = try await TaxScenario.query(on: db)
            .filter(\.$id == id)
            .filter(\.$userId == userId)
            .first()
        else { return nil }
        return try decode(TaxScenarioResponse.self, from: model.responseJSON)
    }
}

extension DefaultTaxService {
    func dismissOpportunity(
        userId: UUID,
        opportunityId: String,
        jurisdiction: TaxJurisdiction,
        taxYear: Int,
        on db: any Database
    ) async throws {
        let current = try await dashboard(
            userId: userId,
            jurisdiction: jurisdiction,
            taxYear: taxYear,
            on: db
        )
        guard let opportunity = current.opportunities.first(where: { $0.id == opportunityId }) else {
            throw Abort(.notFound, reason: "Tax opportunity not found.")
        }
        try await saveOpportunityDecision(
            userId: userId,
            taxYear: taxYear,
            opportunityID: opportunityId,
            benefit: opportunity.estimatedAfterCostBenefit?.amount ?? opportunity.estimatedTaxBenefit.amount,
            currency: opportunity.estimatedTaxBenefit.currency,
            status: .dismissed,
            on: db
        )
    }

    func restoreOpportunity(
        userId: UUID,
        opportunityId: String,
        taxYear: Int,
        on db: any Database
    ) async throws {
        guard let decision = try await TaxOpportunityDecision.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$taxYear == taxYear)
            .filter(\.$opportunityId == opportunityId)
            .first()
        else { return }
        guard decision.status == TaxOpportunityStatus.dismissed.rawValue else {
            throw Abort(.conflict, reason: "Only a dismissed opportunity can be restored.")
        }
        try await decision.delete(on: db)
    }

    func createActionPlan(userId: UUID, request: TaxActionPlanRequest, on db: any Database) async throws -> TaxActionPlanResponse {
        if let existing = try await TaxActionPlan.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$idempotencyKey == request.idempotencyKey)
            .first()
        {
            return try await actionPlanResponse(existing, on: db)
        }
        guard let scenarioID = UUID(uuidString: request.scenarioId),
              let scenario = try await TaxScenario.query(on: db)
              .filter(\.$id == scenarioID)
              .filter(\.$userId == userId)
              .first()
        else { throw Abort(.notFound, reason: "Tax scenario not found.") }
        guard scenario.kind == TaxActionPlanKind.harvest.rawValue else {
            throw Abort(.unprocessableEntity, reason: "Use the placement-plan endpoint for an asset-location scenario.")
        }
        let scenarioRequest = try decode(TaxScenarioRequest.self, from: scenario.requestJSON)
        let scenarioResponse = try decode(TaxScenarioResponse.self, from: scenario.responseJSON)
        guard let profile = try await TaxProfile.find(scenario.profileId, on: db),
              let jurisdiction = TaxJurisdiction(rawValue: profile.jurisdiction)
        else { throw Abort(.unprocessableEntity, reason: "The tax profile for this scenario is no longer available.") }
        let currentDashboard = try await dashboard(
            userId: userId,
            jurisdiction: jurisdiction,
            taxYear: scenarioRequest.taxYear,
            on: db
        )
        let selectedOpportunityIDs = Set(scenarioRequest.opportunityIds)
        let currentOpportunities = currentDashboard.opportunities.filter {
            selectedOpportunityIDs.contains($0.id)
        }
        guard currentOpportunities.count == selectedOpportunityIDs.count,
              currentOpportunities.allSatisfy({
                  $0.status == .actionable && $0.supportLevel == .supported
              })
        else {
            throw Abort(
                .unprocessableEntity,
                reason: "One or more harvesting opportunities are no longer actionable. Run the simulator again with current prices and tax rules."
            )
        }
        let benefitByOpportunityID = Dictionary(uniqueKeysWithValues: currentOpportunities.map {
            ($0.id, $0.estimatedAfterCostBenefit?.amount ?? $0.estimatedTaxBenefit.amount)
        })
        let lotIDs = scenarioRequest.opportunityIds.compactMap(UUID.init(uuidString:))
        let lots = lotIDs.isEmpty ? [] : try await Lot.query(on: db)
            .filter(\.$id ~~ lotIDs)
            .all()
        let lotByID = Dictionary(uniqueKeysWithValues: lots.compactMap { lot in
            lot.id.map { ($0, lot) }
        })
        let accountIDs = Array(Set(lots.map(\.accountId)))
        let accounts = accountIDs.isEmpty ? [] : try await Account.query(on: db)
            .filter(\.$id ~~ accountIDs)
            .filter(\.$userId == userId)
            .all()
        let accountByID = Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
            account.id.map { ($0, account) }
        })
        guard accounts.count == accountIDs.count else {
            throw Abort(.forbidden, reason: "A selected tax lot is no longer available to this user.")
        }
        let replacementIDs = Set((scenarioResponse.selectedReplacements ?? [:]).values.compactMap {
            UUID(uuidString: $0.instrumentId)
        })
        let instrumentIDs = Array(Set(lots.map(\.instrumentId)).union(replacementIDs))
        let instruments = instrumentIDs.isEmpty ? [] : try await Instrument.query(on: db)
            .filter(\.$id ~~ instrumentIDs)
            .all()
        let instrumentByID = Dictionary(uniqueKeysWithValues: instruments.compactMap { instrument in
            instrument.id.map { ($0, instrument) }
        })
        let positions = accountIDs.isEmpty ? [] : try await Position.query(on: db)
            .filter(\.$accountId ~~ accountIDs)
            .all()
        let positionByKey = Dictionary(uniqueKeysWithValues: positions.map {
            (positionKey(account: $0.accountId, instrument: $0.instrumentId), $0)
        })
        let planID = UUID()
        var legs = [TaxActionLeg]()
        for opportunityID in scenarioRequest.opportunityIds {
            guard let lotID = UUID(uuidString: opportunityID),
                  let lot = lotByID[lotID],
                  let account = accountByID[lot.accountId],
                  let instrument = instrumentByID[lot.instrumentId]
            else {
                throw Abort(.unprocessableEntity, reason: "A selected tax lot is no longer open or cannot be valued.")
            }
            let position = positionByKey[positionKey(account: lot.accountId, instrument: lot.instrumentId)]
            let unitPrice = Decimal(position?.lastPrice ?? lot.openPrice)
            let notional = max(0, Decimal(lot.remainingQuantity) * unitPrice)
            legs.append(TaxActionLeg(
                id: UUID().uuidString,
                accountId: lot.accountId.uuidString,
                portfolioId: account.portfolioId?.uuidString,
                instrumentId: lot.instrumentId.uuidString,
                symbol: instrument.symbol,
                side: .sell,
                quantity: Decimal(lot.remainingQuantity),
                notional: TaxMoney(amount: notional, currency: lot.currency),
                lotIds: [opportunityID]
            ))
            if let candidate = scenarioResponse.selectedReplacements?[opportunityID],
               let replacementID = UUID(uuidString: candidate.instrumentId),
               let replacement = instrumentByID[replacementID]
            {
                let replacementPosition = positionByKey[positionKey(account: lot.accountId, instrument: replacementID)]
                let replacementPrice = replacementPosition?.lastPrice.flatMap { $0 > 0 ? Decimal($0) : nil }
                legs.append(TaxActionLeg(
                    id: UUID().uuidString,
                    accountId: lot.accountId.uuidString,
                    portfolioId: account.portfolioId?.uuidString,
                    instrumentId: replacementID.uuidString,
                    symbol: replacement.symbol,
                    side: .buy,
                    quantity: replacementPrice.map { notional / $0 },
                    notional: TaxMoney(amount: notional, currency: lot.currency)
                ))
            }
        }
        guard !legs.isEmpty else {
            throw Abort(.unprocessableEntity, reason: "No open lots remain for this scenario.")
        }
        let steps = scenarioRequest.opportunityIds.enumerated().map { index, opportunityID in
            TaxActionStep(
                id: UUID().uuidString,
                order: index + 1,
                title: "Review and place the proposed disposal",
                detail: "Use your broker to review lot \(opportunityID). Confirm quantity, fees, and replacement activity before submitting.",
                completed: false
            )
        } + [TaxActionStep(
            id: UUID().uuidString,
            order: scenarioRequest.opportunityIds.count + 1,
            title: "Monitor the wash-sale window",
            detail: "Avoid substantially identical acquisitions across household accounts during the applicable window unless your adviser confirms treatment.",
            completed: false
        )]
        let initialResponse = TaxActionPlanResponse(
            id: planID.uuidString,
            scenarioId: request.scenarioId,
            status: "accepted",
            createdAt: isoDate(Date()),
            steps: steps,
            disclaimer: taxDisclaimer,
            kind: .harvest,
            executionStatus: .accepted,
            legs: legs,
            rebalancingPlanIds: []
        )
        let model = TaxActionPlan()
        model.id = planID
        model.userId = userId
        model.scenarioId = scenarioID
        model.kind = TaxActionPlanKind.harvest.rawValue
        model.idempotencyKey = request.idempotencyKey
        model.status = TaxActionPlanStatus.accepted.rawValue
        model.responseJSON = try encode(initialResponse)
        try await model.create(on: db)
        try await persistActionLegs(legs, actionPlanID: planID, on: db)
        let rebalancingPlanIDs = try await TaxRebalancingDraftBridge().createDrafts(
            userId: userId,
            actionPlanID: planID,
            kind: .harvest,
            legs: legs,
            on: db
        )
        for opportunityID in scenarioRequest.opportunityIds {
            let benefit = benefitByOpportunityID[opportunityID] ?? 0
            try await saveOpportunityDecision(
                userId: userId,
                taxYear: scenarioRequest.taxYear,
                opportunityID: opportunityID,
                benefit: benefit,
                currency: scenarioResponse.estimatedNetBenefit.currency,
                status: .accepted,
                on: db
            )
        }
        let response = TaxActionPlanResponse(
            id: initialResponse.id,
            scenarioId: initialResponse.scenarioId,
            status: initialResponse.status,
            createdAt: initialResponse.createdAt,
            steps: initialResponse.steps,
            disclaimer: initialResponse.disclaimer,
            kind: .harvest,
            executionStatus: .accepted,
            legs: legs,
            rebalancingPlanIds: rebalancingPlanIDs.map(\.uuidString)
        )
        model.responseJSON = try encode(response)
        try await model.save(on: db)
        return response
    }

    func actionPlans(userId: UUID, on db: any Database) async throws -> [TaxActionPlanResponse] {
        let models = try await TaxActionPlan.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$createdAt, .descending)
            .all()
        var responses = [TaxActionPlanResponse]()
        for model in models {
            try await responses.append(actionPlanResponse(model, on: db))
        }
        return responses
    }

    func actionPlan(userId: UUID, id: UUID, on db: any Database) async throws -> TaxActionPlanResponse? {
        guard let model = try await TaxActionPlan.query(on: db)
            .filter(\.$id == id)
            .filter(\.$userId == userId)
            .first()
        else { return nil }
        return try await actionPlanResponse(model, on: db)
    }

    func transitionActionPlan(
        userId: UUID,
        id: UUID,
        request: TaxActionPlanTransitionRequest,
        on db: any Database
    ) async throws -> TaxActionPlanResponse {
        guard let model = try await TaxActionPlan.query(on: db)
            .filter(\.$id == id)
            .filter(\.$userId == userId)
            .first()
        else { throw Abort(.notFound, reason: "Tax action plan not found.") }
        guard [TaxActionPlanStatus.completed, .cancelled].contains(request.status) else {
            throw Abort(.unprocessableEntity, reason: "An action plan can only be manually completed or cancelled.")
        }
        guard ![TaxActionPlanStatus.completed.rawValue, TaxActionPlanStatus.cancelled.rawValue].contains(model.status) else {
            if model.status == request.status.rawValue {
                return try await actionPlanResponse(model, on: db)
            }
            throw Abort(.conflict, reason: "A terminal action plan cannot change status.")
        }
        let executedAt = request.executedAt.flatMap(parseTaxDate) ?? Date()
        model.status = request.status.rawValue
        model.executedAt = request.status == .completed ? executedAt : nil
        model.confirmationNote = request.confirmationNote
        try await model.save(on: db)
        let legs = try await TaxActionLegRecord.query(on: db)
            .filter(\.$actionPlanId == id)
            .all()
        for leg in legs {
            leg.status = request.status == .completed
                ? TaxActionLegStatus.completed.rawValue
                : TaxActionLegStatus.cancelled.rawValue
            try await leg.save(on: db)
            if request.status == .completed, leg.side == TaxLocationLegSide.sell.rawValue {
                try await createRestrictionWindow(userId: userId, leg: leg, executedAt: executedAt, on: db)
            }
        }
        return try await actionPlanResponse(model, on: db)
    }

    func createLocationScenario(
        userId: UUID,
        request: TaxLocationScenarioRequest,
        jurisdiction: TaxJurisdiction,
        on db: any Database
    ) async throws -> TaxLocationScenarioResponse {
        let dashboard = try await dashboard(
            userId: userId,
            jurisdiction: jurisdiction,
            taxYear: request.taxYear,
            on: db
        )
        let requested = Set(request.opportunityIds)
        let selected = (dashboard.locationOpportunities ?? []).filter { requested.contains($0.id) }
        guard !selected.isEmpty else {
            throw Abort(.unprocessableEntity, reason: "Select at least one available asset-location opportunity.")
        }
        guard let profile = try await TaxProfile.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$jurisdiction == jurisdiction.rawValue)
            .filter(\.$taxYear == request.taxYear)
            .first()
        else { throw Abort(.unprocessableEntity, reason: "Complete a tax profile first.") }
        let currency = selected.first!.annualSavings.currency
        let annualSavings = selected.reduce(Decimal.zero) { $0 + $1.annualSavings.amount }
        let immediateCost = selected.reduce(Decimal.zero) { $0 + $1.immediateTaxCost.amount }
        let accountIDs = Set(selected.flatMap(\.legs).compactMap { UUID(uuidString: $0.accountId) })
        let accounts = accountIDs.isEmpty ? [] : try await Account.query(on: db)
            .filter(\.$id ~~ Array(accountIDs))
            .filter(\.$userId == userId)
            .all()
        let portfolioIDs = Set(accounts.compactMap(\.portfolioId))
        let impacts = try await TaxGoalImpactCalculator().impacts(
            userId: userId,
            affectedPortfolioIDs: portfolioIDs,
            benefit: max(0, annualSavings - immediateCost),
            currency: currency,
            on: db
        )
        let id = UUID()
        let response = TaxLocationScenarioResponse(
            id: id.uuidString,
            createdAt: isoDate(Date()),
            opportunities: selected,
            annualSavings: TaxMoney(amount: annualSavings, currency: currency),
            immediateTaxCost: TaxMoney(amount: immediateCost, currency: currency),
            goalImpacts: impacts,
            warnings: selected.flatMap(\.warnings),
            assumptions: dashboard.assumptions + ["Annual savings are reinvested immediately when estimating goal impact."]
        )
        let model = TaxScenario()
        model.id = id
        model.userId = userId
        model.profileId = profile.id!
        model.kind = TaxActionPlanKind.assetLocation.rawValue
        model.requestJSON = try encode(request)
        model.responseJSON = try encode(response)
        try await model.create(on: db)
        return response
    }

    func createPlacementPlan(
        userId: UUID,
        request: TaxPlacementPlanRequest,
        on db: any Database
    ) async throws -> TaxActionPlanResponse {
        if let existing = try await TaxActionPlan.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$idempotencyKey == request.idempotencyKey)
            .first()
        {
            return try await actionPlanResponse(existing, on: db)
        }
        guard let scenarioID = UUID(uuidString: request.scenarioId),
              let scenario = try await TaxScenario.query(on: db)
              .filter(\.$id == scenarioID)
              .filter(\.$userId == userId)
              .filter(\.$kind == TaxActionPlanKind.assetLocation.rawValue)
              .first()
        else { throw Abort(.notFound, reason: "Asset-location scenario not found.") }
        let scenarioResponse = try decode(TaxLocationScenarioResponse.self, from: scenario.responseJSON)
        guard !scenarioResponse.opportunities.isEmpty,
              scenarioResponse.opportunities.allSatisfy({ $0.supportLevel == .supported })
        else {
            throw Abort(
                .unprocessableEntity,
                reason: "Asset-location trade plans are only available for fully supported jurisdictions. The estimate remains available for review."
            )
        }
        let accounts = try await Account.query(on: db).filter(\.$userId == userId).all()
        let accountByID = Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
            account.id.map { ($0, account) }
        })
        let legs = try scenarioResponse.opportunities.flatMap(\.legs).map { leg -> TaxActionLeg in
            guard let accountID = UUID(uuidString: leg.accountId),
                  let account = accountByID[accountID]
            else { throw Abort(.forbidden, reason: "An asset-location account is no longer available.") }
            return TaxActionLeg(
                id: UUID().uuidString,
                accountId: leg.accountId,
                portfolioId: account.portfolioId?.uuidString,
                instrumentId: leg.instrumentId,
                symbol: leg.symbol,
                side: leg.side,
                notional: leg.notional
            )
        }
        let planID = UUID()
        let steps = legs.enumerated().map { index, leg in
            TaxActionStep(
                id: UUID().uuidString,
                order: index + 1,
                title: "Review "
                    + leg.side.rawValue.replacingOccurrences(of: "_", with: " ")
                    + " for "
                    + leg.symbol,
                detail: "Confirm account, notional, allocation impact, tax cost, and current quote before trading.",
                completed: false
            )
        }
        let initial = TaxActionPlanResponse(
            id: planID.uuidString,
            scenarioId: request.scenarioId,
            status: TaxActionPlanStatus.accepted.rawValue,
            createdAt: isoDate(Date()),
            steps: steps,
            disclaimer: taxDisclaimer,
            kind: .assetLocation,
            executionStatus: .accepted,
            legs: legs,
            rebalancingPlanIds: []
        )
        let model = TaxActionPlan()
        model.id = planID
        model.userId = userId
        model.scenarioId = scenarioID
        model.kind = TaxActionPlanKind.assetLocation.rawValue
        model.idempotencyKey = request.idempotencyKey
        model.status = TaxActionPlanStatus.accepted.rawValue
        model.responseJSON = try encode(initial)
        try await model.create(on: db)
        try await persistActionLegs(legs, actionPlanID: planID, on: db)
        let linkedIDs = try await TaxRebalancingDraftBridge().createDrafts(
            userId: userId,
            actionPlanID: planID,
            kind: .assetLocation,
            legs: legs,
            on: db
        )
        let response = TaxActionPlanResponse(
            id: initial.id,
            scenarioId: initial.scenarioId,
            status: initial.status,
            createdAt: initial.createdAt,
            steps: initial.steps,
            disclaimer: initial.disclaimer,
            kind: .assetLocation,
            executionStatus: .accepted,
            legs: legs,
            rebalancingPlanIds: linkedIDs.map(\.uuidString)
        )
        model.responseJSON = try encode(response)
        try await model.save(on: db)
        return response
    }

    private func persistActionLegs(
        _ legs: [TaxActionLeg],
        actionPlanID: UUID,
        on db: any Database
    ) async throws {
        for leg in legs {
            guard let id = UUID(uuidString: leg.id),
                  let accountID = UUID(uuidString: leg.accountId),
                  let instrumentID = UUID(uuidString: leg.instrumentId)
            else { throw Abort(.unprocessableEntity, reason: "A tax action leg contains an invalid identifier.") }
            let record = TaxActionLegRecord()
            record.id = id
            record.actionPlanId = actionPlanID
            record.accountId = accountID
            record.portfolioId = leg.portfolioId.flatMap(UUID.init(uuidString:))
            record.instrumentId = instrumentID
            record.symbol = leg.symbol
            record.side = leg.side.rawValue
            record.quantity = leg.quantity.map(decimalDouble)
            record.notional = decimalDouble(leg.notional.amount)
            record.currency = leg.notional.currency
            record.lotIDsJSON = try encode(leg.lotIds)
            record.status = leg.status.rawValue
            record.matchedTransactionId = leg.matchedTransactionId.flatMap(UUID.init(uuidString:))
            try await record.create(on: db)
        }
    }

    private func actionPlanResponse(
        _ model: TaxActionPlan,
        on db: any Database
    ) async throws -> TaxActionPlanResponse {
        let stored = try decode(TaxActionPlanResponse.self, from: model.responseJSON)
        let legRecords = try await TaxActionLegRecord.query(on: db)
            .filter(\.$actionPlanId == model.id!)
            .sort(\.$createdAt, .ascending)
            .all()
        var legs = [TaxActionLeg]()
        for record in legRecords {
            let lotIDs = try decode([String].self, from: record.lotIDsJSON)
            legs.append(TaxActionLeg(
                id: record.id!.uuidString,
                accountId: record.accountId.uuidString,
                portfolioId: record.portfolioId?.uuidString,
                instrumentId: record.instrumentId.uuidString,
                symbol: record.symbol,
                side: TaxLocationLegSide(rawValue: record.side) ?? .buy,
                quantity: record.quantity.map { Decimal($0) },
                notional: TaxMoney(amount: Decimal(record.notional), currency: record.currency),
                lotIds: lotIDs,
                status: TaxActionLegStatus(rawValue: record.status) ?? .planned,
                matchedTransactionId: record.matchedTransactionId?.uuidString
            ))
        }
        let links = try await TaxActionRebalancingPlanLink.query(on: db)
            .filter(\.$actionPlanId == model.id!)
            .sort(\.$createdAt, .ascending)
            .all()
        let executionStatus = TaxActionPlanStatus(rawValue: model.status) ?? .requiresReview
        let terminal = executionStatus == .completed || executionStatus == .cancelled
        let steps = stored.steps.map { step in
            TaxActionStep(
                id: step.id,
                order: step.order,
                title: step.title,
                detail: step.detail,
                earliestDate: step.earliestDate,
                completed: terminal
            )
        }
        return TaxActionPlanResponse(
            id: stored.id,
            scenarioId: stored.scenarioId,
            status: model.status,
            createdAt: stored.createdAt,
            steps: steps,
            disclaimer: stored.disclaimer,
            kind: TaxActionPlanKind(rawValue: model.kind),
            executionStatus: executionStatus,
            legs: legs,
            rebalancingPlanIds: links.map(\.rebalancingPlanId.uuidString)
        )
    }

    private func saveOpportunityDecision(
        userId: UUID,
        taxYear: Int,
        opportunityID: String,
        benefit: Decimal,
        currency: String,
        status: TaxOpportunityStatus,
        on db: any Database
    ) async throws {
        let record = try await TaxOpportunityDecision.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$taxYear == taxYear)
            .filter(\.$opportunityId == opportunityID)
            .first() ?? TaxOpportunityDecision()
        record.userId = userId
        record.taxYear = taxYear
        record.opportunityId = opportunityID
        record.status = status.rawValue
        record.estimatedBenefit = decimalDouble(benefit)
        record.currency = currency
        try await record.save(on: db)
    }

    private func createRestrictionWindow(
        userId: UUID,
        leg: TaxActionLegRecord,
        executedAt: Date,
        on db: any Database
    ) async throws {
        guard try await TaxRestrictionWindow.query(on: db)
            .filter(\.$actionLegId == leg.id!)
            .first() == nil,
            let account = try await Account.query(on: db)
            .filter(\.$id == leg.accountId)
            .filter(\.$userId == userId)
            .first(),
            let jurisdiction = account.taxJurisdiction.flatMap(TaxJurisdiction.init(rawValue:)),
            jurisdiction == .unitedStates,
            let instrument = try await Instrument.find(leg.instrumentId, on: db)
        else { return }
        let identityKey = instrument.taxIdentityGroup
            ?? instrument.cusip
            ?? instrument.isin
            ?? instrument.symbol.uppercased()
        let calendar = Calendar(identifier: .gregorian)
        let window = TaxRestrictionWindow()
        window.userId = userId
        window.actionLegId = leg.id!
        window.jurisdiction = jurisdiction.rawValue
        window.taxIdentityKey = identityKey
        window.startsAt = calendar.date(byAdding: .day, value: -30, to: executedAt)!
        window.endsAt = calendar.date(byAdding: .day, value: 30, to: executedAt)!
        window.status = "active"
        try await window.create(on: db)
        let accountIDs = try await Account.query(on: db)
            .filter(\.$userId == userId)
            .all()
            .compactMap(\.id)
        guard !accountIDs.isEmpty else { return }
        let purchases = try await Transaction.query(on: db)
            .filter(\.$accountId ~~ accountIDs)
            .filter(\.$type == "BUY")
            .filter(\.$tradeDate >= window.startsAt)
            .filter(\.$tradeDate <= window.endsAt)
            .all()
        let instrumentIDs = Array(Set(purchases.map(\.instrumentId)))
        let instruments = instrumentIDs.isEmpty ? [] : try await Instrument.query(on: db)
            .filter(\.$id ~~ instrumentIDs)
            .all()
        let matchingIDs = Set(instruments.compactMap { candidate in
            let candidateKey = candidate.taxIdentityGroup
                ?? candidate.cusip
                ?? candidate.isin
                ?? candidate.symbol.uppercased()
            return candidateKey == identityKey ? candidate.id : nil
        })
        guard let violation = purchases
            .filter({ matchingIDs.contains($0.instrumentId) })
            .sorted(by: { $0.tradeDate < $1.tradeDate })
            .first,
            let transactionID = violation.id
        else { return }
        window.status = "violated"
        window.violatingTransactionId = transactionID
        try await window.save(on: db)
    }

    func notificationPreferences(userId: UUID, on db: any Database) async throws -> TaxNotificationPreferences {
        guard let model = try await TaxNotificationPreference.query(on: db)
            .filter(\.$userId == userId)
            .first()
        else { return TaxNotificationPreferences(enabled: false, cooldownDays: 7) }
        return TaxNotificationPreferences(
            enabled: model.enabled,
            minimumBenefit: model.minimumBenefit.map { Decimal($0) },
            cooldownDays: model.cooldownDays
        )
    }

    func saveNotificationPreferences(
        userId: UUID,
        request: TaxNotificationPreferences,
        on db: any Database
    ) async throws -> TaxNotificationPreferences {
        let model = try await TaxNotificationPreference.query(on: db)
            .filter(\.$userId == userId)
            .first() ?? TaxNotificationPreference()
        model.userId = userId
        model.enabled = request.enabled
        model.minimumBenefit = request.minimumBenefit.map(decimalDouble)
        model.cooldownDays = max(1, request.cooldownDays)
        try await model.save(on: db)
        return TaxNotificationPreferences(
            enabled: model.enabled,
            minimumBenefit: model.minimumBenefit.map { Decimal($0) },
            cooldownDays: model.cooldownDays
        )
    }

    private func realizedLiability(
        accountIDs: [UUID],
        taxYear: Int,
        profile: TaxProfileRequest,
        pack: ConfiguredTaxRulePack,
        on db: any Database
    ) async throws -> Decimal {
        guard !accountIDs.isEmpty else { return 0 }
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: taxYear, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: taxYear + 1, month: 1, day: 1))!
        if profile.jurisdiction == .portugal {
            guard let owner = try await Account.query(on: db)
                .filter(\.$id ~~ accountIDs)
                .first()
            else { return 0 }
            let sourceLots = try await Lot.query(on: db)
                .filter(\.$accountId ~~ accountIDs)
                .all()
            let lotByID = Dictionary(uniqueKeysWithValues: sourceLots.compactMap { lot in
                lot.id.map { ($0, lot) }
            })
            let lotIDs = Array(lotByID.keys)
            guard !lotIDs.isEmpty else { return 0 }
            let disposals = try await LotDisposal.query(on: db)
                .filter(\.$lotId ~~ lotIDs)
                .all()
            let transactionIDs = Array(Set(disposals.map(\.transactionId)))
            let transactions = transactionIDs.isEmpty ? [] : try await Transaction.query(on: db)
                .filter(\.$id ~~ transactionIDs)
                .filter(\.$tradeDate >= start)
                .filter(\.$tradeDate < end)
                .all()
            let transactionByID = Dictionary(uniqueKeysWithValues: transactions.compactMap { transaction in
                transaction.id.map { ($0, transaction) }
            })
            let positions = disposals.compactMap { disposal -> PortugalRealizedPosition? in
                guard let lot = lotByID[disposal.lotId],
                      let transaction = transactionByID[disposal.transactionId]
                else { return nil }
                let holdingDays = max(0, calendar.dateComponents(
                    [.day],
                    from: lot.openDate,
                    to: transaction.tradeDate
                ).day ?? 0)
                return .init(realizedPnL: Decimal(disposal.realizedPnl), holdingDays: holdingDays)
            }
            let ledger = PortugalLossCarryforwardLedger()
            let persistedCarryforward = try await ledger.available(
                userId: owner.userId,
                taxYear: taxYear,
                on: db
            )
            let manuallyEnteredCarryforward = max(
                0,
                profile.priorShortTermLossCarryover + profile.priorLongTermLossCarryover
            )
            let result = PortugalCapitalGainsCalculator().calculate(
                positions: positions,
                estimatedTaxableIncome: profile.estimatedTaxableIncome,
                marginalRate: profile.marginalIncomeTaxRate ?? PortugalCapitalGainsCalculator.autonomousRate,
                taxationMode: profile.capitalGainsTaxationMode,
                eligibleLossCarryforward: max(persistedCarryforward, manuallyEnteredCarryforward)
            )
            try await ledger.reconcile(
                userId: owner.userId,
                taxYear: taxYear,
                currency: profile.reportingCurrency,
                ruleVersion: pack.ruleVersion,
                result: result,
                on: db
            )
            return result.estimatedTax
        }
        if pack.jurisdiction == .germany {
            guard let owner = try await Account.query(on: db)
                .filter(\.$id ~~ accountIDs)
                .first()
            else { return 0 }
            let transactions = try await Transaction.query(on: db)
                .filter(\.$accountId ~~ accountIDs)
                .filter(\.$type == "SELL")
                .filter(\.$tradeDate >= start)
                .filter(\.$tradeDate < end)
                .all()
            let instrumentIDs = Set(transactions.map(\.instrumentId))
            let instruments = instrumentIDs.isEmpty ? [] : try await Instrument.query(on: db)
                .filter(\.$id ~~ Array(instrumentIDs))
                .all()
            let stockInstrumentIDs = Set(instruments.compactMap { instrument -> UUID? in
                guard let id = instrument.id,
                      ["stock", "equity"].contains(instrument.instrumentType?.lowercased() ?? "")
                else { return nil }
                return id
            })
            let transactionIDs = transactions.compactMap { transaction -> UUID? in
                guard stockInstrumentIDs.contains(transaction.instrumentId) else { return nil }
                return transaction.id
            }
            let disposals = transactionIDs.isEmpty ? [] : try await LotDisposal.query(on: db)
                .filter(\.$transactionId ~~ transactionIDs)
                .all()
            let annualResult = disposals.reduce(Decimal.zero) { result, disposal in
                result + Decimal(disposal.realizedPnl)
            }
            let reconciled = try await GermanyStockLossLedger().reconcile(
                userId: owner.userId,
                taxYear: taxYear,
                netStockResult: annualResult,
                ruleVersion: pack.ruleVersion,
                on: db
            )
            let transactionByID = Dictionary(uniqueKeysWithValues: transactions.compactMap { transaction in
                transaction.id.map { ($0, transaction) }
            })
            let fundClassifications = Dictionary(uniqueKeysWithValues: instruments.compactMap { instrument -> (UUID, TaxFundClassification)? in
                guard let id = instrument.id,
                      ["etf", "fund", "mutual_fund"].contains(instrument.instrumentType?.lowercased() ?? ""),
                      let classification = instrument.fundClassification.flatMap(TaxFundClassification.init(rawValue:)),
                      GermanyFundPartialExemptionCalculator.exemptionRate(for: classification) != nil
                else { return nil }
                return (id, classification)
            })
            let fundTransactionIDs = transactions.compactMap { transaction -> UUID? in
                guard fundClassifications[transaction.instrumentId] != nil else { return nil }
                return transaction.id
            }
            let fundDisposals = fundTransactionIDs.isEmpty ? [] : try await LotDisposal.query(on: db)
                .filter(\.$transactionId ~~ fundTransactionIDs)
                .all()
            let fundDisposalIDs = Set(fundDisposals.compactMap(\.id))
            let advanceAllocations = try await GermanyFundAdvanceAllocationService().reconcile(
                disposalIDs: fundDisposalIDs,
                on: db
            )
            let adjustedFundResult = fundDisposals.reduce(Decimal.zero) { result, disposal in
                guard let transaction = transactionByID[disposal.transactionId],
                      let classification = fundClassifications[transaction.instrumentId],
                      let adjusted = GermanyFundPartialExemptionCalculator.taxableAmount(
                          Decimal(disposal.realizedPnl) - (disposal.id.flatMap { advanceAllocations[$0] } ?? 0),
                          classification: classification
                      )
                else { return result }
                return result + adjusted
            }
            let generalReconciled = try await GermanyGeneralLossLedger().reconcile(
                userId: owner.userId,
                taxYear: taxYear,
                netCapitalResult: reconciled.taxableStockGain + adjustedFundResult,
                ruleVersion: pack.ruleVersion,
                on: db
            )
            return GermanyCapitalGainsCalculator.estimatedTax(
                taxableStockGain: generalReconciled.taxableCapitalGain,
                remainingCapitalIncomeAllowance: profile.remainingCapitalIncomeAllowance,
                churchTaxRate: profile.churchTaxRate
            )
        }
        let lots = try await Lot.query(on: db)
            .filter(\.$accountId ~~ accountIDs)
            .filter(\.$closeDate >= start)
            .filter(\.$closeDate < end)
            .all()
        return lots.reduce(Decimal.zero) { result, lot in
            guard let pnl = lot.realizedPnl, pnl > 0,
                  let closeDate = lot.closeDate,
                  let rate = pack.rate(isLongTerm: closeDate.timeIntervalSince(lot.openDate) > 365 * 86400, profile: profile)
            else { return result }
            return result + Decimal(pnl) * rate
        }
    }

    private func hasRecentReplacement(
        userId: UUID,
        instrument: Instrument,
        since: Date,
        excludingTransactionId: UUID?,
        on db: any Database
    ) async throws -> Bool {
        let accounts = try await Account.query(on: db).filter(\.$userId == userId).all()
        let accountIDs = accounts.compactMap(\.id)
        guard !accountIDs.isEmpty, let instrumentID = instrument.id else { return false }
        var matchingIDs = [instrumentID]
        if let identity = instrument.taxIdentityGroup {
            matchingIDs = try await Instrument.query(on: db)
                .filter(\.$taxIdentityGroup == identity)
                .all()
                .compactMap(\.id)
        }
        let transactions = try await Transaction.query(on: db)
            .filter(\.$accountId ~~ accountIDs)
            .filter(\.$instrumentId ~~ matchingIDs)
            .filter(\.$tradeDate >= since)
            .filter(\.$type ~~ ["BUY", "BOT", "buy"])
            .all()
        return transactions.contains { transaction in
            transaction.id != excludingTransactionId && abs(transaction.quantity ?? 0) > 0.000_000_1
        }
    }

    private func storeSnapshot(
        _ response: TaxDashboardResponse,
        userId: UUID,
        profileId: UUID,
        on db: any Database
    ) async throws {
        let json = try encode(response)
        let digest = SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
        let model = TaxProjectionSnapshot()
        model.userId = userId
        model.profileId = profileId
        model.taxYear = response.taxYear
        model.jurisdiction = response.jurisdiction.rawValue
        model.ruleVersion = response.ruleVersion
        model.status = "ready"
        model.responseJSON = json
        model.inputHash = digest
        model.generatedAt = Date()
        try await model.create(on: db)
    }

    private func profileResponse(_ model: TaxProfile) throws -> TaxProfileResponse {
        let request = try decode(TaxProfileRequest.self, from: model.profileJSON)
        return TaxProfileResponse(
            id: model.id!.uuidString,
            profile: request,
            isComplete: model.isComplete,
            missingFields: missingFields(request),
            updatedAt: isoDate(model.updatedAt ?? model.createdAt ?? Date())
        )
    }

    private func missingFields(_ request: TaxProfileRequest) -> [String] {
        var missing = [String]()
        if request.members.isEmpty {
            missing.append("members")
        }
        if request.accounts.isEmpty {
            missing.append("accounts")
        }
        if request.accounts.contains(where: { $0.wrapper == .unknown }) {
            missing.append("account_wrappers")
        }
        if request.reportingCurrency.count != 3 {
            missing.append("reporting_currency")
        }
        if request.jurisdiction == .unitedStates {
            if request.shortTermCapitalGainsRate == nil {
                missing.append("short_term_capital_gains_rate")
            }
            if request.longTermCapitalGainsRate == nil {
                missing.append("long_term_capital_gains_rate")
            }
        } else if request.marginalIncomeTaxRate == nil {
            missing.append("marginal_income_tax_rate")
        }
        return missing
    }

    private func emptyDashboard(
        jurisdiction: TaxJurisdiction,
        taxYear: Int,
        currency: String
    ) -> TaxDashboardResponse {
        let zero = TaxMoney(amount: 0, currency: currency)
        return TaxDashboardResponse(
            generatedAt: isoDate(Date()),
            taxYear: taxYear,
            jurisdiction: jurisdiction,
            ruleVersion: rules.pack(for: jurisdiction).ruleVersion,
            isStale: false,
            profileComplete: false,
            summary: TaxProjectionSummary(
                realizedEstimatedLiability: zero,
                embeddedUnrealizedLiability: zero,
                harvestableLosses: zero,
                estimatedNetBenefit: zero,
                shortTermCarryover: zero,
                longTermCarryover: zero,
                taxCostRatio: nil
            ),
            opportunities: [],
            unsupportedValue: zero,
            assumptions: ["Complete a tax profile and classify investment accounts to enable calculations."],
            disclaimer: taxDisclaimer
        )
    }
}

private func taxInstrumentMarketOption(_ instrument: Instrument) -> TaxInstrumentMarketOption? {
    guard let id = instrument.id else { return nil }
    return TaxInstrumentMarketOption(
        id: id.uuidString,
        symbol: instrument.symbol,
        listingExchange: instrument.listingExchange,
        marketAdmissionStatus: instrument.regulatedMarketSource == nil
            ? .unknown
            : instrument.regulatedMarketStatus.flatMap(TaxMarketAdmissionStatus.init(rawValue:)) ?? .unknown,
        fundClassification: instrument.fundClassification.flatMap(TaxFundClassification.init(rawValue:))
    )
}

private func defaultCurrency(_ jurisdiction: TaxJurisdiction) -> String {
    jurisdiction == .unitedStates ? "USD" : "EUR"
}

private func positionKey(account: UUID, instrument: UUID) -> String {
    "\(account.uuidString):\(instrument.uuidString)"
}

private func taxPriceQuality(position: Position?, now: Date) -> TaxPriceQuality {
    guard position?.lastPrice != nil, let pricedAt = position?.lastPriceDate else { return .missing }
    return now.timeIntervalSince(pricedAt) <= 86400 ? .fresh : .stale
}

private func decimalDouble(_ value: Decimal) -> Double {
    NSDecimalNumber(decimal: value).doubleValue
}

private func encode(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try String(decoding: encoder.encode(value), as: UTF8.self)
}

private func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(value.utf8))
}

private func parseTaxDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

func isoDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
