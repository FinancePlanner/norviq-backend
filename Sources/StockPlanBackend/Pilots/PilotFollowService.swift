import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Creates follows. A follow never touches a real portfolio: portfolio targets
/// must be hypothetical, not the default, and empty. Anything else would mix
/// simulated trades into numbers the user relies on.
struct PilotFollowService: Sendable {
    static let proFollowLimit = 10
    static let freeFollowLimit = 1
    static let maxStartingCapital = 10_000_000.0
    /// The Pro portfolio limit enforced by PortfolioManagementController.create.
    static let proPortfolioLimit = 25

    private let mirror: PilotMirrorService

    init(mirror: PilotMirrorService) {
        self.mirror = mirror
    }

    func create(_ request: PilotFollowCreateRequest, userId: UUID, entitlement: EntitlementSnapshot, now: Date, on db: any Database) async throws -> PilotFollow {
        guard let pilot = try await Pilot.query(on: db).filter(\.$slug == request.pilotSlug).filter(\.$active == true).first() else {
            throw Abort(.notFound, reason: "Pilot not found.")
        }
        let pilotId = try pilot.requireID()
        guard let latest = try await PilotBookVersion.query(on: db).filter(\.$pilotId == pilotId).sort(\.$version, .descending).first() else {
            throw Abort(.conflict, reason: "This pilot has no disclosures yet. Try again later.")
        }

        let existing = try await PilotFollow.query(on: db).filter(\.$userId == userId).count()
        let limit = entitlement.isPro ? Self.proFollowLimit : Self.freeFollowLimit
        if request.targetKind == .portfolio, !entitlement.isPro {
            throw BillingUpgradeRequiredError(feature: .pilotFollows, plan: entitlement.level)
        }
        guard existing < limit else {
            throw BillingUpgradeRequiredError(feature: .pilotFollows, plan: entitlement.level, limit: limit, current: existing)
        }

        let follow: PilotFollow = try await db.transaction { tx in
            switch request.targetKind {
            case .portfolio:
                guard let capital = request.startingCapital, capital > 0, capital <= Self.maxStartingCapital else {
                    throw Abort(.badRequest, reason: "Starting capital must be between 0 and 10,000,000.")
                }
                let listId = try await portfolioTarget(request.portfolioListId, pilot: pilot, userId: userId, on: tx)
                let account = try await PilotAccountResolver.findOrCreate(userId: userId, portfolioId: listId, on: tx)
                try await CashBalance(accountId: account.requireID(), currency: account.baseCurrency, balance: capital, asOf: now).create(on: tx)
                try await ensureNotFollowing(userId: userId, pilotId: pilotId, portfolioListId: listId, watchlistListId: nil, on: tx)
                let follow = PilotFollow(userId: userId, pilotId: pilotId, targetKind: .portfolio, portfolioListId: listId, startingCapital: capital, currency: account.baseCurrency)
                try await follow.create(on: tx)
                return follow
            case .watchlist:
                let listId = try await watchlistTarget(request.watchlistListId, pilot: pilot, userId: userId, on: tx)
                try await ensureNotFollowing(userId: userId, pilotId: pilotId, portfolioListId: nil, watchlistListId: listId, on: tx)
                let follow = PilotFollow(userId: userId, pilotId: pilotId, targetKind: .watchlist, watchlistListId: listId)
                try await follow.create(on: tx)
                return follow
            }
        }

        // Applied after the commit: quotes reach the network and must not run
        // inside the transaction. If this fails, the follow stays at version 0
        // and the mirror job catches it up on its next tick.
        do {
            if try await mirror.apply(follow: follow, pilot: pilot, version: latest, previous: nil, now: now, on: db) {
                follow.appliedVersion = latest.version
            }
        } catch {
            db.logger.warning("pilot_follow initial apply failed follow_id=\(follow.id?.uuidString ?? "?") error=\(error)")
        }
        return follow
    }

    private func ensureNotFollowing(userId: UUID, pilotId: UUID, portfolioListId: UUID?, watchlistListId: UUID?, on db: any Database) async throws {
        var query = PilotFollow.query(on: db).filter(\.$userId == userId).filter(\.$pilotId == pilotId)
        if let portfolioListId {
            query = query.filter(\.$portfolioListId == portfolioListId)
        }
        if let watchlistListId {
            query = query.filter(\.$watchlistListId == watchlistListId)
        }
        if try await query.count() > 0 {
            throw Abort(.conflict, reason: "You already follow this pilot there.")
        }
    }

    private func portfolioTarget(_ rawId: String?, pilot: Pilot, userId: UUID, on db: any Database) async throws -> UUID {
        if let rawId {
            guard let id = UUID(uuidString: rawId),
                  let list = try await PortfolioList.query(on: db).filter(\.$id == id).filter(\.$userId == userId).first()
            else { throw Abort(.notFound, reason: "Portfolio not found.") }
            guard list.mode == PortfolioMode.hypothetical.rawValue, !list.isDefault, list.archivedAt == nil else {
                throw Abort(.unprocessableEntity, reason: "Pilots can only be followed into a hypothetical portfolio, never your main or a real one.")
            }
            let held = try await Stock.query(on: db).filter(\.$portfolioListId == id).count()
            let followed = try await PilotFollow.query(on: db).filter(\.$portfolioListId == id).count()
            let accountIds = try await Account.query(on: db).filter(\.$portfolioId == id).all().map { try $0.requireID() }
            var ledger = 0
            if !accountIds.isEmpty {
                ledger += try await CashBalance.query(on: db).filter(\.$accountId ~~ accountIds).count()
                ledger += try await Transaction.query(on: db).filter(\.$accountId ~~ accountIds).count()
            }
            let cashPositions = try await PortfolioCashPositionRecord.query(on: db).filter(\.$portfolioId == id).count()
            guard held == 0, followed == 0, ledger == 0, cashPositions == 0 else {
                throw Abort(.unprocessableEntity, reason: "Choose an empty hypothetical portfolio, or let Norviq create one.")
            }
            // A broker sync writes real holdings into its bound list.
            guard try await BrokerConnection.query(on: db).filter(\.$portfolioListId == id).count() == 0 else {
                throw Abort(.unprocessableEntity, reason: "This portfolio is linked to a broker connection. Choose another, or let Norviq create one.")
            }
            return id
        }
        let count = try await PortfolioList.query(on: db).filter(\.$userId == userId).filter(\.$archivedAt == nil).count()
        guard count < Self.proPortfolioLimit else {
            throw BillingUpgradeRequiredError(feature: .portfolioLists, plan: "pro", limit: Self.proPortfolioLimit, current: count)
        }
        let list = try await PortfolioList(userId: userId, name: uniqueName("\(pilot.displayName) copy", userId: userId, on: db), mode: PortfolioMode.hypothetical.rawValue)
        try await list.create(on: db)
        return try list.requireID()
    }

    private func watchlistTarget(_ rawId: String?, pilot: Pilot, userId: UUID, on db: any Database) async throws -> UUID {
        if let rawId {
            guard let id = UUID(uuidString: rawId),
                  try await WatchlistList.query(on: db).filter(\.$id == id).filter(\.$userId == userId).first() != nil
            else { throw Abort(.notFound, reason: "Watchlist not found.") }
            // Like a portfolio target: the mirror rewrites statuses and notes,
            // so it must never adopt items the user wrote by hand.
            // Adds without a list land in the default watchlist.
            guard try await WatchlistList.find(id, on: db)?.isDefault != true else {
                throw Abort(.unprocessableEntity, reason: "Pilots can't be followed into your main watchlist. Choose another, or let Norviq create one.")
            }
            let items = try await WatchlistItem.query(on: db).filter(\.$watchlistListId == id).count()
            let followed = try await PilotFollow.query(on: db).filter(\.$watchlistListId == id).count()
            guard items == 0, followed == 0 else {
                throw Abort(.unprocessableEntity, reason: "Choose an empty watchlist, or let Norviq create one.")
            }
            return id
        }
        let taken = try await Set(WatchlistList.query(on: db).filter(\.$userId == userId).all().map(\.name))
        let base = "\(pilot.displayName) feed"
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base) \(n)"; n += 1
        }
        let list = WatchlistList(userId: userId, name: name)
        try await list.create(on: db)
        return try list.requireID()
    }

    /// Portfolio names are unique per user; "X copy", then "X copy 2", and so on.
    private func uniqueName(_ base: String, userId: UUID, on db: any Database) async throws -> String {
        let taken = try await Set(PortfolioList.query(on: db).filter(\.$userId == userId).all().map(\.name))
        if !taken.contains(base) {
            return base
        }
        var n = 2
        while taken.contains("\(base) \(n)") {
            n += 1
        }
        return "\(base) \(n)"
    }
}
