import Fluent
import Foundation
import StockPlanShared
import Vapor

protocol ThesisWatchServicing: Sendable {
    func refreshClusters(on db: any Database) async throws
    func feed(
        userId: UUID,
        scope: ThesisWatchScope,
        sector: String?,
        limit: Int,
        cursor: String?,
        on db: any Database
    ) async throws -> ThesisWatchFeedResponse
    func story(id: UUID, userId: UUID, on db: any Database) async throws -> ThesisWatchStory
    func feedback(id: UUID, userId: UUID, signal: ThesisWatchFeedbackSignal, on db: any Database) async throws
    func markRead(id: UUID, userId: UUID, on db: any Database) async throws
    func notificationPreferences(userId: UUID, on db: any Database) async throws -> ThesisWatchNotificationPreferences
    func updateNotificationPreferences(
        userId: UUID,
        payload: UpdateThesisWatchNotificationPreferences,
        on db: any Database
    ) async throws -> ThesisWatchNotificationPreferences
}

struct ThesisWatchClassifier: Sendable {
    func classify(headline: String, summary: String?) -> (ThesisWatchEventType, ThesisWatchSeverity) {
        let text = "\(headline) \(summary ?? "")".lowercased()
        let rules: [(ThesisWatchEventType, [String])] = [
            (.guidance, ["guidance", "outlook", "forecast", "profit warning"]),
            (.earnings, ["earnings", "revenue", "quarter", "eps", "results"]),
            (.regulation, ["regulator", "regulation", "antitrust", "sec ", "fda", "eu commission"]),
            (.mergerAcquisition, ["acquire", "acquisition", "merger", "takeover", "buyout"]),
            (.management, ["ceo", "cfo", "chairman", "executive", "resigns", "appointed"]),
            (.capitalReturn, ["dividend", "buyback", "repurchase", "capital return"]),
            (.legal, ["lawsuit", "court", "settlement", "probe", "investigation"]),
            (.analystAction, ["upgrade", "downgrade", "price target", "analyst"]),
            (.product, ["launch", "product", "approval", "recall", "patent"]),
            (.macro, ["inflation", "interest rate", "fed ", "ecb ", "tariff", "recession"]),
        ]
        let event = rules.first(where: { rule in rule.1.contains(where: text.contains) })?.0 ?? .other
        let highTerms = ["bankruptcy", "fraud", "recall", "profit warning", "cuts guidance", "investigation", "takeover"]
        let mediumTerms = ["earnings", "guidance", "dividend", "ceo", "merger", "lawsuit", "approval", "downgrade"]
        let severity: ThesisWatchSeverity = if highTerms.contains(where: text.contains) {
            .high
        } else if mediumTerms.contains(where: text.contains) {
            .medium
        } else {
            .low
        }
        return (event, severity)
    }
}

struct ThesisWatchRanker: Sendable {
    func score(
        relationship: ThesisWatchRelationship,
        weightPercent: Double,
        severity: ThesisWatchSeverity,
        impact: ThesisWatchImpact,
        publishedAt: Date,
        feedback: ThesisWatchFeedbackSignal?,
        now: Date = Date()
    ) -> Double {
        let relationshipScore: Double = switch relationship {
        case .holding: 40
        case .watchlist: 15
        case .market: 0
        }
        let ageHours = max(0, now.timeIntervalSince(publishedAt) / 3600)
        let freshness = max(0, 20 * (1 - ageHours / 72))
        let severityScore: Double = switch severity {
        case .high: 15
        case .medium: 7
        case .low: 0
        }
        let impactScore: Double = switch impact {
        case .challenges: 10
        case .supports: 4
        default: 0
        }
        return relationshipScore
            + min(max(weightPercent, 0), 20)
            + freshness
            + severityScore
            + impactScore
            + (feedback == .relevant ? 5 : 0)
    }
}

struct DefaultThesisWatchService: ThesisWatchServicing {
    private let billingContextService: any BillingContextService
    private let classifier = ThesisWatchClassifier()
    private let ranker = ThesisWatchRanker()

    init(billingContextService: any BillingContextService) {
        self.billingContextService = billingContextService
    }

    func refreshClusters(on db: any Database) async throws {
        let since = Date().addingTimeInterval(-30 * 86400)
        let articles = try await MarketNewsArchive.query(on: db)
            .filter(\.$publishedAt >= since)
            .filter(\.$storyId == nil)
            .sort(\.$publishedAt, .ascending)
            .all()

        for article in articles {
            guard let articleId = article.id else { continue }
            let clusterKey = makeClusterKey(article)
            let story: ThesisWatchStoryModel
            if let existing = try await ThesisWatchStoryModel.query(on: db)
                .filter(\.$clusterKey == clusterKey)
                .first()
            {
                story = existing
                if article.publishedAt > existing.lastSeenAt {
                    existing.lastSeenAt = article.publishedAt
                    existing.representativeNewsId = articleId
                    let classification = classifier.classify(headline: article.headline, summary: article.summary)
                    existing.eventType = classification.0.rawValue
                    existing.severity = classification.1.rawValue
                    try await existing.save(on: db)
                }
            } else {
                let classification = classifier.classify(headline: article.headline, summary: article.summary)
                let candidate = ThesisWatchStoryModel(
                    clusterKey: clusterKey,
                    representativeNewsId: articleId,
                    eventType: classification.0.rawValue,
                    severity: classification.1.rawValue,
                    firstSeenAt: article.publishedAt,
                    lastSeenAt: article.publishedAt
                )
                do {
                    try await candidate.save(on: db)
                    story = candidate
                } catch {
                    guard let concurrent = try await ThesisWatchStoryModel.query(on: db)
                        .filter(\.$clusterKey == clusterKey)
                        .first()
                    else { throw error }
                    story = concurrent
                }
            }
            article.storyId = try story.requireID()
            try await article.save(on: db)
        }
    }

    func feed(
        userId: UUID,
        scope: ThesisWatchScope,
        sector requestedSector: String?,
        limit: Int,
        cursor: String?,
        on db: any Database
    ) async throws -> ThesisWatchFeedResponse {
        try await refreshClusters(on: db)
        let billing = try await billingContextService.context(userId: userId, on: db)
        let isPro = billing.isPro
        let effectiveLimit = min(max(limit, 1), isPro ? 50 : 10)
        let offset = max(Int(cursor ?? "") ?? 0, 0)

        let stocks = try await Stock.query(on: db).filter(\.$userId == userId).all()
        let holdings = Dictionary(grouping: stocks, by: { $0.symbol.uppercased() })
            .mapValues { rows in rows.reduce(0) { $0 + max(0, $1.shares * $1.buyPrice) } }
        let totalValue = holdings.values.reduce(0, +)
        let watchlistSymbols = try await Set(WatchlistItem.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$status == WatchlistStatus.active.rawValue)
            .all()
            .map { $0.symbol.uppercased() })
        let trackedSymbols = Set(holdings.keys).union(watchlistSymbols)
        let profiles = try await ProfileCache.query(on: db)
            .filter(\.$symbol ~~ Array(trackedSymbols))
            .all()
        let sectorsBySymbol = Dictionary(uniqueKeysWithValues: profiles.compactMap { profile in
            profile.finnhubIndustry.map { (profile.symbol.uppercased(), $0) }
        })
        let notes = try await ResearchNote.query(on: db).filter(\.$userId == userId).all()
        let notesBySymbol = Dictionary(grouping: notes, by: { $0.symbol.uppercased() })

        let since = Date().addingTimeInterval(-30 * 86400)
        let articles = try await MarketNewsArchive.query(on: db)
            .filter(\.$publishedAt >= since)
            .sort(\.$publishedAt, .descending)
            .limit(500)
            .all()
        let relevantArticles = articles.filter { article in
            article.symbol == "GENERAL" || trackedSymbols.contains(article.symbol.uppercased())
        }
        let storyIds = Set(relevantArticles.compactMap(\.storyId))
        let stories = try await ThesisWatchStoryModel.query(on: db)
            .filter(\.$id ~~ Array(storyIds))
            .all()
        let storiesById = Dictionary(uniqueKeysWithValues: stories.compactMap { story in
            story.id.map { ($0, story) }
        })
        let states = try await ThesisWatchUserState.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$storyId ~~ Array(storyIds))
            .all()
        var statesByStory = Dictionary(uniqueKeysWithValues: states.map { ($0.storyId, $0) })

        let grouped = Dictionary(grouping: relevantArticles, by: \.storyId)
        var ranked: [(Double, ThesisWatchStory)] = []
        for (optionalStoryId, clusterArticles) in grouped {
            guard let storyId = optionalStoryId,
                  let storyModel = storiesById[storyId],
                  let representative = clusterArticles.max(by: { $0.publishedAt < $1.publishedAt }),
                  let url = representative.url,
                  let eventType = ThesisWatchEventType(rawValue: storyModel.eventType),
                  let severity = ThesisWatchSeverity(rawValue: storyModel.severity)
            else { continue }

            let symbols = Array(Set(clusterArticles.map { $0.symbol.uppercased() }.filter { $0 != "GENERAL" })).sorted()
            let holdingSymbol = symbols.max(by: { (holdings[$0] ?? 0) < (holdings[$1] ?? 0) })
            let relationship: ThesisWatchRelationship = if symbols.contains(where: { holdings[$0] != nil }) {
                .holding
            } else if symbols.contains(where: watchlistSymbols.contains) {
                .watchlist
            } else {
                .market
            }
            let value = symbols.reduce(0) { $0 + (holdings[$1] ?? 0) }
            let weight = totalValue > 0 ? value / totalValue * 100 : 0
            let sectors = Array(Set(symbols.compactMap { sectorsBySymbol[$0] })).sorted()

            guard includes(scope: scope, relationship: relationship, sectors: sectors, requestedSector: requestedSector) else {
                continue
            }

            var state = statesByStory[storyId]
            if isPro, state == nil, let symbol = holdingSymbol ?? symbols.first {
                let candidate = makeAnalysisState(
                    userId: userId,
                    storyId: storyId,
                    symbol: symbol,
                    headline: representative.headline,
                    providerSummary: representative.summary,
                    exposureWeight: weight,
                    notes: notesBySymbol[symbol] ?? []
                )
                if let candidate {
                    do {
                        try await candidate.save(on: db)
                        state = candidate
                    } catch {
                        state = try await ThesisWatchUserState.query(on: db)
                            .filter(\.$userId == userId)
                            .filter(\.$storyId == storyId)
                            .first()
                        if state == nil {
                            throw error
                        }
                    }
                    statesByStory[storyId] = state
                }
            }
            if state?.dismissedAt != nil || state?.feedback == ThesisWatchFeedbackSignal.notRelevant.rawValue {
                continue
            }
            let impact = ThesisWatchImpact(rawValue: state?.impact ?? "") ?? .notAssessed
            let feedback = state?.feedback.flatMap(ThesisWatchFeedbackSignal.init(rawValue:))
            let exposure = isPro && value > 0
                ? ThesisWatchExposure(currency: "USD", value: value, weightPercent: weight)
                : nil
            let dto = ThesisWatchStory(
                id: storyId.uuidString,
                headline: representative.headline,
                source: representative.source,
                url: url,
                imageUrl: representative.imageURL,
                publishedAt: iso8601(representative.publishedAt),
                providerSummary: representative.summary,
                summary: isPro ? state?.summary : nil,
                whyItMatters: isPro ? state?.whyItMatters : nil,
                symbols: symbols,
                sectors: sectors,
                relationship: relationship,
                eventType: eventType,
                severity: severity,
                exposure: exposure,
                thesisImpact: isPro ? impact : .notAssessed,
                confidence: isPro ? state?.confidence : nil,
                feedback: feedback,
                isRead: state?.readAt != nil,
                isDismissed: false
            )
            let score = isPro
                ? ranker.score(
                    relationship: relationship,
                    weightPercent: weight,
                    severity: severity,
                    impact: impact,
                    publishedAt: representative.publishedAt,
                    feedback: feedback
                )
                : representative.publishedAt.timeIntervalSince1970
            ranked.append((score, dto))
        }

        ranked.sort { lhs, rhs in lhs.0 == rhs.0 ? lhs.1.publishedAt > rhs.1.publishedAt : lhs.0 > rhs.0 }
        let page = Array(ranked.dropFirst(offset).prefix(effectiveLimit).map(\.1))
        let nextOffset = offset + page.count
        let nextCursor = nextOffset < ranked.count ? String(nextOffset) : nil
        return ThesisWatchFeedResponse(
            items: page,
            nextCursor: nextCursor,
            generatedAt: iso8601(Date()),
            capabilities: ThesisWatchCapabilities(
                isPro: isPro,
                personalizedRanking: isPro,
                thesisAnalysis: isPro,
                pushAlerts: isPro,
                maxItems: isPro ? 50 : 10
            )
        )
    }

    func story(id: UUID, userId: UUID, on db: any Database) async throws -> ThesisWatchStory {
        let result = try await feed(userId: userId, scope: .forYou, sector: nil, limit: 50, cursor: nil, on: db)
        guard let story = result.items.first(where: { $0.id.caseInsensitiveCompare(id.uuidString) == .orderedSame }) else {
            throw Abort(.notFound, reason: "Thesis Watch story not found.")
        }
        return story
    }

    func feedback(id: UUID, userId: UUID, signal: ThesisWatchFeedbackSignal, on db: any Database) async throws {
        let state = try await state(id: id, userId: userId, on: db)
        if signal == .clear {
            state.feedback = nil
            state.dismissedAt = nil
        } else {
            state.feedback = signal.rawValue
            state.dismissedAt = signal == .notRelevant ? Date() : nil
            if [.supports, .challenges, .neutral].contains(signal) {
                state.impact = signal.rawValue
            }
        }
        try await state.save(on: db)
    }

    func markRead(id: UUID, userId: UUID, on db: any Database) async throws {
        let state = try await state(id: id, userId: userId, on: db)
        state.readAt = Date()
        try await state.save(on: db)
    }

    func notificationPreferences(userId: UUID, on db: any Database) async throws -> ThesisWatchNotificationPreferences {
        let preference = try await ThesisWatchNotificationPreference.query(on: db)
            .filter(\.$userId == userId)
            .first()
        return .init(enabled: preference?.enabled ?? false, timezone: preference?.timezone ?? "UTC")
    }

    func updateNotificationPreferences(
        userId: UUID,
        payload: UpdateThesisWatchNotificationPreferences,
        on db: any Database
    ) async throws -> ThesisWatchNotificationPreferences {
        let timezone = payload.timezone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TimeZone(identifier: timezone) != nil else {
            throw Abort(.badRequest, reason: "Invalid timezone identifier.")
        }
        let billing = try await billingContextService.context(userId: userId, on: db)
        guard !payload.enabled || billing.isPro else {
            throw Abort(.paymentRequired, reason: "Thesis Watch push alerts require Pro.")
        }
        let preference = try await ThesisWatchNotificationPreference.query(on: db)
            .filter(\.$userId == userId)
            .first() ?? ThesisWatchNotificationPreference(userId: userId)
        preference.enabled = payload.enabled
        preference.timezone = timezone
        try await preference.save(on: db)
        return .init(enabled: preference.enabled, timezone: preference.timezone)
    }
}

private extension DefaultThesisWatchService {
    func state(id: UUID, userId: UUID, on db: any Database) async throws -> ThesisWatchUserState {
        guard try await ThesisWatchStoryModel.find(id, on: db) != nil else {
            throw Abort(.notFound, reason: "Thesis Watch story not found.")
        }
        if let existing = try await ThesisWatchUserState.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$storyId == id)
            .first()
        {
            return existing
        }
        return ThesisWatchUserState(userId: userId, storyId: id)
    }

    func makeClusterKey(_ article: MarketNewsArchive) -> String {
        let day = Int(article.publishedAt.timeIntervalSince1970 / 86400)
        let normalized = article.headline.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(day):\(String(normalized.prefix(240)))"
    }

    func includes(
        scope: ThesisWatchScope,
        relationship: ThesisWatchRelationship,
        sectors: [String],
        requestedSector: String?
    ) -> Bool {
        switch scope {
        case .forYou:
            return relationship != .market
        case .holdings:
            return relationship == .holding
        case .watchlist:
            return relationship == .watchlist
        case .sectors:
            guard let requestedSector, !requestedSector.isEmpty else { return !sectors.isEmpty }
            return sectors.contains { $0.localizedCaseInsensitiveCompare(requestedSector) == .orderedSame }
        case .market:
            return true
        }
    }

    func makeAnalysisState(
        userId: UUID,
        storyId: UUID,
        symbol: String,
        headline: String,
        providerSummary: String?,
        exposureWeight: Double,
        notes: [ResearchNote]
    ) -> ThesisWatchUserState? {
        guard let note = notes.max(by: { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }) else {
            return nil
        }
        let articleText = "\(headline) \(providerSummary ?? "")".lowercased()
        let riskMatch = overlapScore(articleText, note.risks)
        let catalystMatch = overlapScore(articleText, note.catalysts)
        let impact: ThesisWatchImpact
        let confidence: Double
        if riskMatch > catalystMatch, riskMatch > 0 {
            impact = .challenges
            confidence = min(0.9, 0.55 + Double(riskMatch) * 0.08)
        } else if catalystMatch > 0 {
            impact = .supports
            confidence = min(0.9, 0.55 + Double(catalystMatch) * 0.08)
        } else {
            impact = .insufficientEvidence
            confidence = 0.35
        }
        let state = ThesisWatchUserState(userId: userId, storyId: storyId, impact: impact.rawValue)
        state.symbol = symbol
        state.confidence = confidence
        state.summary = conciseSummary(headline: headline, providerSummary: providerSummary)
        let exposureText = exposureWeight > 0 ? String(format: "%.1f%% of your recorded cost basis", exposureWeight) : "your watchlist"
        state.whyItMatters = switch impact {
        case .challenges: "This overlaps a risk in your \(symbol) thesis and touches \(exposureText). Review whether the original risk limit still holds."
        case .supports: "This overlaps a catalyst in your \(symbol) thesis and touches \(exposureText). Check whether the evidence changes your expected timing."
        default: "This affects \(symbol), which represents \(exposureText). The available article evidence is not strong enough to change your thesis."
        }
        return state
    }

    func overlapScore(_ articleText: String, _ noteText: String?) -> Int {
        guard let noteText else { return 0 }
        let ignored = Set(["about", "after", "again", "could", "from", "have", "into", "more", "that", "their", "there", "these", "this", "with", "would"])
        let tokens = noteText.lowercased().split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 && !ignored.contains($0) }
        return Set(tokens).reduce(0) { $0 + (articleText.contains($1) ? 1 : 0) }
    }

    func conciseSummary(headline: String, providerSummary: String?) -> String {
        guard let providerSummary = providerSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !providerSummary.isEmpty else {
            return headline
        }
        return String(providerSummary.prefix(320))
    }

    func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

extension Application {
    private struct ThesisWatchServiceKey: StorageKey {
        typealias Value = any ThesisWatchServicing
    }

    var thesisWatchService: any ThesisWatchServicing {
        get {
            guard let service = storage[ThesisWatchServiceKey.self] else {
                fatalError("ThesisWatchServicing not configured")
            }
            return service
        }
        set { storage[ThesisWatchServiceKey.self] = newValue }
    }
}

extension Request {
    var thesisWatchService: any ThesisWatchServicing {
        application.thesisWatchService
    }
}
