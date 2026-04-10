import Fluent
import Foundation
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
            req.logger.warning("target-alert query failed error=\(String(reflecting: error))")
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
                "target-alert quote lookup failed symbol=\(target.symbol) error=\(String(reflecting: error))"
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
                "target-alert device query failed userId=\(target.userId.uuidString) error=\(String(reflecting: error))"
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

        target.alertTriggeredAt = Date()
        target.alertTriggeredPrice = currentPrice

        do {
            try await target.save(on: req.db)
            req.logger.info(
                "target-alert marked triggered symbol=\(target.symbol) scenario=\(target.scenario) currentPrice=\(currentPrice)"
            )
        } catch {
            req.logger.warning(
                "target-alert save failed symbol=\(target.symbol) error=\(String(reflecting: error))"
            )
        }
    }

    private func shouldTrigger(target: Target, currentPrice: Double) -> Bool {
        switch target.scenario.lowercased() {
        case "bear":
            return currentPrice <= target.targetPrice
        case "base", "bull":
            return currentPrice >= target.targetPrice
        default:
            return false
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
