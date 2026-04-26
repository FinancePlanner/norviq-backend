import Fluent
import Foundation
import StockPlanShared
import Vapor

protocol TargetAlertEvaluating: Sendable {
    func evaluateUnresolvedTargets(req: Request) async
}

struct DefaultTargetAlertEvaluator: TargetAlertEvaluating {
    func evaluateUnresolvedTargets(req: Request) async {
        let unresolvedTargets: [Target]
        do {
            unresolvedTargets = try await Target.query(on: req.db)
                .filter(\.$alertTriggeredAt == nil)
                .all()
        } catch {
            req.logger.warning("target-alert query failed error_type=\(String(reflecting: type(of: error)))")
            return
        }

        guard !unresolvedTargets.isEmpty else {
            return
        }

        for target in unresolvedTargets {
            await evaluate(target: target, req: req)
        }
    }

    private func evaluate(target: Target, req: Request) async {
        let quote: QuoteResponse
        do {
            quote = try await req.application.marketDataService.quote(symbol: target.symbol, on: req)
        } catch {
            req.logger.warning(
                "target-alert quote lookup failed symbol=\(target.symbol) error_type=\(String(reflecting: type(of: error)))"
            )
            return
        }

        let currentPrice = quote.currentPrice
        guard shouldTrigger(target: target, currentPrice: currentPrice) else {
            return
        }

        let devices: [PushDevice]
        do {
            devices = try await req.pushDeviceService.activeDevices(userId: target.userId, on: req.db)
        } catch {
            req.logger.warning(
                "target-alert device query failed userId=\(target.userId.uuidString) error_type=\(String(reflecting: type(of: error)))"
            )
            return
        }

        guard !devices.isEmpty else {
            return
        }

        let summary = await req.application.pushNotificationSender.sendTargetHit(
            target: target,
            currentPrice: currentPrice,
            devices: devices,
            req: req
        )

        guard summary.delivered > 0 else {
            req.logger.warning(
                "target-alert no successful deliveries symbol=\(target.symbol) failed=\(summary.failed)"
            )
            return
        }

        do {
            let marked = try await markTriggeredIfNeeded(targetId: target.id, price: currentPrice, on: req.db)
            guard marked else {
                req.logger.debug(
                    "target-alert already triggered by another worker symbol=\(target.symbol)"
                )
                return
            }
            req.logger.info(
                "target-alert marked triggered symbol=\(target.symbol) scenario=\(target.scenario) currentPrice=\(currentPrice)"
            )
        } catch {
            req.logger.warning(
                "target-alert save failed symbol=\(target.symbol) error_type=\(String(reflecting: type(of: error)))"
            )
        }
    }

    private func shouldTrigger(target: Target, currentPrice: Double) -> Bool {
        switch target.scenario.lowercased() {
        case "bear":
            currentPrice <= target.targetPrice
        case "base", "bull":
            currentPrice >= target.targetPrice
        default:
            false
        }
    }

    private func markTriggeredIfNeeded(
        targetId: UUID?,
        price: Double,
        on db: any Database
    ) async throws -> Bool {
        guard let targetId else { return false }
        return try await db.transaction { tx in
            guard let current = try await Target.find(targetId, on: tx) else {
                return false
            }
            guard current.alertTriggeredAt == nil else {
                return false
            }
            current.alertTriggeredAt = Date()
            current.alertTriggeredPrice = price
            try await current.save(on: tx)
            return true
        }
    }
}

extension Application {
    private struct TargetAlertEvaluatorKey: StorageKey {
        typealias Value = any TargetAlertEvaluating
    }

    var targetAlertEvaluator: any TargetAlertEvaluating {
        get {
            guard let evaluator = storage[TargetAlertEvaluatorKey.self] else {
                fatalError("TargetAlertEvaluating not configured")
            }
            return evaluator
        }
        set {
            storage[TargetAlertEvaluatorKey.self] = newValue
        }
    }
}
