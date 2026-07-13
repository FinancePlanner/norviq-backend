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
    func notificationPreferences(userId: UUID, on db: any Database) async throws -> TaxNotificationPreferences
    func saveNotificationPreferences(userId: UUID, request: TaxNotificationPreferences, on db: any Database) async throws -> TaxNotificationPreferences
    func saveMarketAdmission(userId: UUID, instrumentId: UUID, status: TaxMarketAdmissionStatus, on db: any Database) async throws -> TaxInstrumentMarketOption
    func saveFundClassification(userId: UUID, instrumentId: UUID, classification: TaxFundClassification, on db: any Database) async throws -> TaxInstrumentMarketOption
}

struct DefaultTaxService: TaxService {
    let rules: TaxRuleRegistry

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
            let price = position?.lastPrice ?? position.map(\.averageCost) ?? lot.openPrice
            let marketValue = Decimal(price * lot.remainingQuantity)
            let basis = Decimal(lot.openPrice * lot.remainingQuantity)
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
                on: db
            )
            let actionable = support == .supported && !recentReplacement && profileModel.isComplete
            let status: TaxOpportunityStatus = actionable ? .actionable : (recentReplacement ? .blocked : .watch)
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
            opportunities.append(TaxOpportunityResponse(
                id: lot.id!.uuidString,
                accountId: lot.accountId.uuidString,
                instrumentId: lot.instrumentId.uuidString,
                symbol: instrument.symbol,
                instrumentType: instrumentType,
                status: status,
                supportLevel: support,
                marketValue: TaxMoney(amount: marketValue, currency: profile.reportingCurrency),
                unrealizedLoss: TaxMoney(amount: loss, currency: profile.reportingCurrency),
                estimatedTaxBenefit: TaxMoney(amount: benefit, currency: profile.reportingCurrency),
                eligibleQuantity: Decimal(lot.remainingQuantity),
                holdingPeriod: isLongTerm ? "long_term" : "short_term",
                washSaleWindowEndsAt: recentReplacement ? isoDate(Calendar.current.date(byAdding: .day, value: 31, to: now)!) : nil,
                warnings: warnings,
                confidence: support == .supported ? Decimal(string: "0.95")! : Decimal(string: "0.50")!
            ))
            harvestableLosses += loss
            if actionable {
                estimatedBenefit += benefit
            }
        }

        let realized = try await realizedLiability(
            accountIDs: accountIDs,
            taxYear: taxYear,
            profile: profile,
            pack: pack,
            on: db
        )
        opportunities.sort { $0.estimatedTaxBenefit.amount > $1.estimatedTaxBenefit.amount }
        let currency = profile.reportingCurrency
        let summary = TaxProjectionSummary(
            realizedEstimatedLiability: TaxMoney(amount: realized, currency: currency),
            embeddedUnrealizedLiability: TaxMoney(amount: embeddedLiability, currency: currency),
            harvestableLosses: TaxMoney(amount: harvestableLosses, currency: currency),
            estimatedNetBenefit: TaxMoney(amount: estimatedBenefit, currency: currency),
            shortTermCarryover: TaxMoney(amount: profile.priorShortTermLossCarryover, currency: currency),
            longTermCarryover: TaxMoney(amount: profile.priorLongTermLossCarryover, currency: currency),
            taxCostRatio: nil
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
            disclaimer: taxDisclaimer
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
        let benefit = selected.reduce(Decimal.zero) { $0 + $1.estimatedTaxBenefit.amount }
        let losses = selected.reduce(Decimal.zero) { $0 + $1.unrealizedLoss.amount }
        let currency = dashboard.summary.estimatedNetBenefit.currency
        let baselineTax = dashboard.summary.realizedEstimatedLiability.amount
            + dashboard.summary.embeddedUnrealizedLiability.amount
        let fees = selected.reduce(Decimal.zero) { partial, item in
            partial + item.marketValue.amount * Decimal(string: "0.001")!
        }
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
            assumptions: dashboard.assumptions
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

    func createActionPlan(userId: UUID, request: TaxActionPlanRequest, on db: any Database) async throws -> TaxActionPlanResponse {
        if let existing = try await TaxActionPlan.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$idempotencyKey == request.idempotencyKey)
            .first()
        {
            return try decode(TaxActionPlanResponse.self, from: existing.responseJSON)
        }
        guard let scenarioID = UUID(uuidString: request.scenarioId),
              let scenario = try await TaxScenario.query(on: db)
              .filter(\.$id == scenarioID)
              .filter(\.$userId == userId)
              .first()
        else { throw Abort(.notFound, reason: "Tax scenario not found.") }
        let scenarioRequest = try decode(TaxScenarioRequest.self, from: scenario.requestJSON)
        let planID = UUID()
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
        let response = TaxActionPlanResponse(
            id: planID.uuidString,
            scenarioId: request.scenarioId,
            status: "accepted",
            createdAt: isoDate(Date()),
            steps: steps,
            disclaimer: taxDisclaimer
        )
        let model = TaxActionPlan()
        model.id = planID
        model.userId = userId
        model.scenarioId = scenarioID
        model.idempotencyKey = request.idempotencyKey
        model.status = "accepted"
        model.responseJSON = try encode(response)
        try await model.create(on: db)
        return response
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
        return try await Transaction.query(on: db)
            .filter(\.$accountId ~~ accountIDs)
            .filter(\.$instrumentId ~~ matchingIDs)
            .filter(\.$tradeDate >= since)
            .filter(\.$type ~~ ["BUY", "BOT", "buy"])
            .count() > 0
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

func isoDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
