import Fluent
import Foundation
import StockPlanShared
import Vapor

struct PortfolioAccessContext {
    let portfolio: PortfolioList
    let role: PortfolioRole
    let ownerEntitlement: EntitlementSnapshot

    var isOwner: Bool {
        role == .owner
    }

    var isAdvanced: Bool {
        portfolio.purpose != PortfolioPurpose.personal.rawValue
            || portfolio.ownership != PortfolioOwnership.individual.rawValue
            || portfolio.mode != PortfolioMode.actual.rawValue
    }

    var canEdit: Bool {
        if isAdvanced, ownerEntitlement.isPro == false {
            return false
        }
        return role == .owner || role == .editor
    }

    var capabilities: PortfolioCapabilities {
        PortfolioCapabilities(
            canView: true,
            canEdit: canEdit,
            canManageMembers: isOwner && ownerEntitlement.isPro,
            canManageConnections: isOwner && canEdit && portfolio.mode == PortfolioMode.actual.rawValue,
            canArchive: isOwner,
            canDelete: isOwner
        )
    }
}

struct PortfolioAccessService: Sendable {
    let entitlementResolver: any EntitlementResolver

    func require(
        portfolioId: UUID,
        userId: UUID,
        editing: Bool = false,
        ownerOnly: Bool = false,
        on database: any Database
    ) async throws -> PortfolioAccessContext {
        guard let portfolio = try await PortfolioList.find(portfolioId, on: database) else {
            throw Abort(.notFound, reason: "Portfolio not found.")
        }

        let role: PortfolioRole
        if portfolio.userId == userId {
            role = .owner
        } else if let membership = try await PortfolioMembershipRecord.query(on: database)
            .filter(\.$portfolioId == portfolioId)
            .filter(\.$userId == userId)
            .filter(\.$status == "active")
            .first()
        {
            role = PortfolioRole(rawValue: membership.role) ?? .editor
        } else {
            throw Abort(.notFound, reason: "Portfolio not found.")
        }

        let entitlement = try await entitlementResolver.resolve(userId: portfolio.userId, on: database)
        let context = PortfolioAccessContext(
            portfolio: portfolio,
            role: role,
            ownerEntitlement: entitlement
        )
        if ownerOnly, context.isOwner == false {
            throw Abort(.forbidden, reason: "Only the portfolio owner can perform this action.")
        }
        if editing, context.canEdit == false {
            throw BillingUpgradeRequiredError(feature: .advancedPortfolios, plan: entitlement.level)
        }
        return context
    }
}

extension Application {
    private struct PortfolioAccessServiceKey: StorageKey {
        typealias Value = PortfolioAccessService
    }

    var portfolioAccessService: PortfolioAccessService {
        get {
            guard let service = storage[PortfolioAccessServiceKey.self] else {
                fatalError("PortfolioAccessService not configured")
            }
            return service
        }
        set { storage[PortfolioAccessServiceKey.self] = newValue }
    }
}

extension Request {
    var portfolioAccessService: PortfolioAccessService {
        application.portfolioAccessService
    }
}
