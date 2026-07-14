import APNS
import APNSCore
import Foundation
import StockPlanShared
import Vapor
import VaporAPNS

struct TargetPushSendSummary {
    let delivered: Int
    let failed: Int
}

struct AutomationPushMessage: Sendable {
    let eventId: UUID
    let kind: NotificationEventKind
    let title: String
    let body: String
    let deepLink: String?
    let payload: [String: String]
}

protocol PushNotificationSending: Sendable {
    func sendTargetHit(
        target: Target,
        currentPrice: Double,
        devices: [PushDevice],
        req: Request
    ) async -> TargetPushSendSummary

    func sendBudgetAlert(
        snapshot: BudgetSnapshot,
        threshold: Int,
        remainingAmount: Double,
        devices: [PushDevice],
        req: Request
    ) async -> TargetPushSendSummary

    func sendEarningsReminder(
        symbol: String,
        earningsDate: String,
        leadDays: Int,
        devices: [PushDevice],
        req: Request
    ) async -> TargetPushSendSummary

    func sendTaxOpportunity(
        opportunity: TaxOpportunityResponse,
        devices: [PushDevice],
        req: Request
    ) async -> TargetPushSendSummary

    func sendAutomationAlert(
        message: AutomationPushMessage,
        devices: [PushDevice],
        req: Request
    ) async -> TargetPushSendSummary

    func sendRebalancingDrift(
        alert: RebalancingAlert,
        portfolioName: String,
        devices: [PushDevice],
        req: Request
    ) async -> TargetPushSendSummary
}

struct NoopPushNotificationSender: PushNotificationSending {
    func sendAutomationAlert(
        message: AutomationPushMessage,
        devices: [PushDevice],
        req: Request
    ) async -> TargetPushSendSummary {
        req.logger.debug(
            "push.notifications disabled automation kind=\(message.kind.rawValue) devices=\(devices.count)"
        )
        return .init(delivered: 0, failed: devices.count)
    }

    func sendTaxOpportunity(
        opportunity: TaxOpportunityResponse,
        devices: [PushDevice],
        req: Request
    ) async -> TargetPushSendSummary {
        req.logger.debug("push.notifications disabled tax_opportunity symbol=\(opportunity.symbol) devices=\(devices.count)")
        return .init(delivered: 0, failed: devices.count)
    }

    func sendTargetHit(
        target: Target,
        currentPrice _: Double,
        devices: [PushDevice],
        req: Request
    ) async -> TargetPushSendSummary {
        req.logger.debug(
            "push.notifications disabled symbol=\(target.symbol) scenario=\(target.scenario) devices=\(devices.count)"
        )
        return .init(delivered: 0, failed: devices.count)
    }

    func sendBudgetAlert(
        snapshot _: BudgetSnapshot,
        threshold: Int,
        remainingAmount _: Double,
        devices: [PushDevice],
        req: Request
    ) async -> TargetPushSendSummary {
        req.logger.debug(
            "push.notifications disabled budget_alert threshold=\(threshold) devices=\(devices.count)"
        )
        return .init(delivered: 0, failed: devices.count)
    }

    func sendEarningsReminder(
        symbol: String,
        earningsDate: String,
        leadDays: Int,
        devices: [PushDevice],
        req: Request
    ) async -> TargetPushSendSummary {
        req.logger.debug(
            "push.notifications disabled earnings_reminder symbol=\(symbol) earningsDate=\(earningsDate) leadDays=\(leadDays) devices=\(devices.count)"
        )
        return .init(delivered: 0, failed: devices.count)
    }
}

struct APNSPushNotificationSender: PushNotificationSending {
    private static let targetAlertCategoryID = "TARGET_ALERT"
    private static let earningsReminderCategoryID = "EARNINGS_REMINDER"

    struct Payload: Codable {
        let schemaVersion: Int
        let type: String
        let symbol: String
        let scenario: String
        let targetId: String?
        let deepLink: String?
        let targetPrice: Double
        let currentPrice: Double
    }

    struct BudgetAlertPayload: Codable {
        let schemaVersion: Int
        let type: String
        let threshold: Int
        let snapshotId: String?
        let deepLink: String?
        let remainingAmount: Double
    }

    struct EarningsReminderPayload: Codable {
        let schemaVersion: Int
        let type: String
        let symbol: String
        let earningsDate: String
        let leadDays: Int
        let deepLink: String?
    }

    struct TaxOpportunityPayload: Codable {
        let schemaVersion: Int
        let type: String
        let opportunityId: String
        let instrumentId: String
        let symbol: String
        let estimatedBenefit: Decimal
        let currency: String
        let deepLink: String
    }

    struct RebalancingDriftPayload: Codable {
        let schemaVersion: Int
        let type: String
        let alertId: String
        let portfolioId: String
        let modelId: String
        let scopeName: String
        let driftBasisPoints: Int
        let thresholdBasisPoints: Int
        let deepLink: String
    }

    struct AutomationAlertPayload: Codable {
        let schemaVersion: Int
        let type: String
        let eventId: String
        let deepLink: String?
        let data: [String: String]
    }

    let topic: String

    func sendAutomationAlert(
        message: AutomationPushMessage,
        devices: [PushDevice],
        req: Request
    ) async -> TargetPushSendSummary {
        guard devices.isEmpty == false else { return .init(delivered: 0, failed: 0) }
        let payload = AutomationAlertPayload(
            schemaVersion: 1,
            type: message.kind.rawValue,
            eventId: message.eventId.uuidString,
            deepLink: message.deepLink,
            data: message.payload
        )
        let notification = APNSAlertNotification(
            alert: .init(title: .raw(message.title), body: .raw(message.body)),
            expiration: .immediately,
            priority: .immediately,
            topic: topic,
            payload: payload,
            threadID: "automation-\(message.kind.rawValue)",
            category: "WEALTH_AUTOMATION"
        )
        var delivered = 0
        var failed = 0
        for device in devices {
            do {
                _ = try await client(for: device, req: req).sendAlertNotification(
                    notification,
                    deviceToken: device.deviceToken
                )
                delivered += 1
            } catch {
                failed += 1
                req.logger.warning(
                    "push.notifications send failed automation kind=\(message.kind.rawValue) error_type=\(String(reflecting: type(of: error)))"
                )
                if isInvalidTokenError(error) {
                    try? await req.pushDeviceService.deactivate(deviceToken: device.deviceToken, on: req.db)
                }
            }
        }
        return .init(delivered: delivered, failed: failed)
    }

    func sendRebalancingDrift(
        alert: RebalancingAlert,
        portfolioName: String,
        devices: [PushDevice],
        req: Request
    ) async -> TargetPushSendSummary {
        guard !devices.isEmpty else { return .init(delivered: 0, failed: 0) }
        let payload = RebalancingDriftPayload(
            schemaVersion: 1,
            type: "rebalance_drift",
            alertId: alert.id,
            portfolioId: alert.portfolioId,
            modelId: alert.modelId,
            scopeName: alert.scopeName,
            driftBasisPoints: alert.driftBasisPoints,
            thresholdBasisPoints: alert.thresholdBasisPoints,
            deepLink: "financeplan://portfolios/\(alert.portfolioId)/rebalancing"
        )
        let drift = String(format: "%.2f%%", Double(abs(alert.driftBasisPoints)) / 100)
        let notification = APNSAlertNotification(
            alert: .init(
                title: .raw("Portfolio drift: \(portfolioName)"),
                body: .raw("\(alert.scopeName) drifted \(drift), above your threshold. Review the plan before acting.")
            ),
            expiration: .immediately,
            priority: .immediately,
            topic: topic,
            payload: payload,
            threadID: "rebalance-\(alert.portfolioId)-\(alert.scopeId)",
            category: "REBALANCE_DRIFT"
        )
        var delivered = 0
        var failed = 0
        for device in devices {
            do {
                _ = try await client(for: device, req: req).sendAlertNotification(
                    notification,
                    deviceToken: device.deviceToken
                )
                delivered += 1
            } catch {
                failed += 1
                req.logger.warning(
                    "push.notifications send failed rebalance_drift portfolio=\(alert.portfolioId) error_type=\(String(reflecting: type(of: error)))"
                )
                if isInvalidTokenError(error) {
                    try? await req.pushDeviceService.deactivate(deviceToken: device.deviceToken, on: req.db)
                }
            }
        }
        return .init(delivered: delivered, failed: failed)
    }

    func sendTaxOpportunity(
        opportunity: TaxOpportunityResponse,
        devices: [PushDevice],
        req: Request
    ) async -> TargetPushSendSummary {
        guard !devices.isEmpty else { return .init(delivered: 0, failed: 0) }
        let benefit = NSDecimalNumber(decimal: opportunity.estimatedTaxBenefit.amount).doubleValue
        let payload = TaxOpportunityPayload(
            schemaVersion: 1,
            type: "tax_harvest_opportunity",
            opportunityId: opportunity.id,
            instrumentId: opportunity.instrumentId,
            symbol: opportunity.symbol,
            estimatedBenefit: opportunity.estimatedTaxBenefit.amount,
            currency: opportunity.estimatedTaxBenefit.currency,
            deepLink: "financeplan://tax/opportunities/\(opportunity.id)"
        )
        let notification = APNSAlertNotification(
            alert: .init(
                title: .raw("Tax opportunity: \(opportunity.symbol)"),
                body: .raw("Estimated benefit \(formatPrice(benefit, currency: opportunity.estimatedTaxBenefit.currency)). Review before acting.")
            ),
            expiration: .immediately,
            priority: .immediately,
            topic: topic,
            payload: payload,
            threadID: "tax-\(opportunity.instrumentId)",
            category: "TAX_OPPORTUNITY"
        )
        var delivered = 0
        var failed = 0
        for device in devices {
            do {
                _ = try await client(for: device, req: req).sendAlertNotification(notification, deviceToken: device.deviceToken)
                delivered += 1
            } catch {
                failed += 1
                if isInvalidTokenError(error) {
                    try? await req.pushDeviceService.deactivate(deviceToken: device.deviceToken, on: req.db)
                }
            }
        }
        return .init(delivered: delivered, failed: failed)
    }

    func sendBudgetAlert(
        snapshot: BudgetSnapshot,
        threshold: Int,
        remainingAmount: Double,
        devices: [PushDevice],
        req: Request
    ) async -> TargetPushSendSummary {
        guard !devices.isEmpty else {
            return .init(delivered: 0, failed: 0)
        }

        let title = "Budget Alert"
        let body = "You have reached \(threshold)% of your monthly budget. Remaining: \(formatPrice(remainingAmount))."
        let payload = BudgetAlertPayload(
            schemaVersion: 1,
            type: "budget_alert",
            threshold: threshold,
            snapshotId: snapshot.id?.uuidString,
            deepLink: "financeplan://budget",
            remainingAmount: remainingAmount
        )
        let notification = APNSAlertNotification(
            alert: .init(
                title: .raw(title),
                body: .raw(body)
            ),
            expiration: .immediately,
            priority: .immediately,
            topic: topic,
            payload: payload,
            threadID: "budget-\(snapshot.id?.uuidString ?? "general")",
            category: "BUDGET_ALERT"
        )

        var delivered = 0
        var failed = 0

        for device in devices {
            do {
                let client = client(for: device, req: req)
                _ = try await client.sendAlertNotification(
                    notification,
                    deviceToken: device.deviceToken
                )
                delivered += 1
            } catch {
                failed += 1
                req.logger.warning(
                    "push.notifications send failed budget_alert threshold=\(threshold) error_type=\(String(reflecting: type(of: error)))"
                )
                if isInvalidTokenError(error) {
                    try? await req.pushDeviceService.deactivate(deviceToken: device.deviceToken, on: req.db)
                }
            }
        }

        req.logger.info(
            "push.analytics delivered_summary budget_alert threshold=\(threshold) delivered=\(delivered) failed=\(failed)"
        )

        return .init(delivered: delivered, failed: failed)
    }

    func sendTargetHit(
        target: Target,
        currentPrice: Double,
        devices: [PushDevice],
        req: Request
    ) async -> TargetPushSendSummary {
        guard !devices.isEmpty else {
            return .init(delivered: 0, failed: 0)
        }

        let title = "Target hit: \(target.symbol)"
        let body = "Scenario \(target.scenario.uppercased()) reached \(formatPrice(currentPrice)) vs \(formatPrice(target.targetPrice))."
        let payload = Payload(
            schemaVersion: 1,
            type: "target_hit",
            symbol: target.symbol,
            scenario: target.scenario,
            targetId: target.id?.uuidString,
            deepLink: "financeplan://stocks/\(target.symbol)",
            targetPrice: target.targetPrice,
            currentPrice: currentPrice
        )
        let notification = APNSAlertNotification(
            alert: .init(
                title: .raw(title),
                body: .raw(body)
            ),
            expiration: .immediately,
            priority: .immediately,
            topic: topic,
            payload: payload,
            threadID: "target-\(target.symbol.uppercased())",
            category: Self.targetAlertCategoryID
        )

        var delivered = 0
        var failed = 0

        for device in devices {
            do {
                let client = client(for: device, req: req)
                _ = try await client.sendAlertNotification(
                    notification,
                    deviceToken: device.deviceToken
                )
                delivered += 1
            } catch {
                failed += 1
                req.logger.warning(
                    "push.notifications send failed symbol=\(target.symbol) error_type=\(String(reflecting: type(of: error)))"
                )
                if isInvalidTokenError(error) {
                    try? await req.pushDeviceService.deactivate(deviceToken: device.deviceToken, on: req.db)
                }
            }
        }

        req.logger.info(
            "push.analytics delivered_summary symbol=\(target.symbol) scenario=\(target.scenario) delivered=\(delivered) failed=\(failed)"
        )

        return .init(delivered: delivered, failed: failed)
    }

    func sendEarningsReminder(
        symbol: String,
        earningsDate: String,
        leadDays: Int,
        devices: [PushDevice],
        req: Request
    ) async -> TargetPushSendSummary {
        guard !devices.isEmpty else {
            return .init(delivered: 0, failed: 0)
        }

        let normalizedSymbol = symbol.uppercased()
        let when = leadDays == 1 ? "tomorrow" : "in \(leadDays) days"
        let title = "Earnings soon: \(normalizedSymbol)"
        let body = "\(normalizedSymbol) reports earnings \(when) (\(earningsDate))."
        let payload = EarningsReminderPayload(
            schemaVersion: 1,
            type: "earnings_reminder",
            symbol: normalizedSymbol,
            earningsDate: earningsDate,
            leadDays: leadDays,
            deepLink: "financeplan://stocks/\(normalizedSymbol)"
        )
        let notification = APNSAlertNotification(
            alert: .init(
                title: .raw(title),
                body: .raw(body)
            ),
            expiration: .immediately,
            priority: .immediately,
            topic: topic,
            payload: payload,
            threadID: "earnings-\(normalizedSymbol)-\(earningsDate)-\(leadDays)",
            category: Self.earningsReminderCategoryID
        )

        var delivered = 0
        var failed = 0

        for device in devices {
            do {
                let client = client(for: device, req: req)
                _ = try await client.sendAlertNotification(
                    notification,
                    deviceToken: device.deviceToken
                )
                delivered += 1
            } catch {
                failed += 1
                req.logger.warning(
                    "push.notifications send failed earnings_reminder symbol=\(normalizedSymbol) earningsDate=\(earningsDate) leadDays=\(leadDays) error_type=\(String(reflecting: type(of: error)))"
                )
                if isInvalidTokenError(error) {
                    try? await req.pushDeviceService.deactivate(deviceToken: device.deviceToken, on: req.db)
                }
            }
        }

        req.logger.info(
            "push.analytics delivered_summary earnings_reminder symbol=\(normalizedSymbol) earningsDate=\(earningsDate) leadDays=\(leadDays) delivered=\(delivered) failed=\(failed)"
        )

        return .init(delivered: delivered, failed: failed)
    }

    private func client(for device: PushDevice, req: Request) -> any APNSClientProtocol {
        if device.apnsEnvironment == PushAPNSEnvironment.production.rawValue {
            return req.apns.client(.production)
        }
        return req.apns.client(.development)
    }

    private func isInvalidTokenError(_ error: any Error) -> Bool {
        guard let apnsError = error as? APNSError else {
            return false
        }

        guard let reason = apnsError.reason?.reason else {
            return false
        }

        return reason == APNSError.ErrorReason.badDeviceToken.reason
            || reason == APNSError.ErrorReason.unregistered.reason
            || reason == APNSError.ErrorReason.deviceTokenNotForTopic.reason
    }

    private func formatPrice(_ value: Double) -> String {
        formatPrice(value, currency: "USD")
    }

    private func formatPrice(_ value: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

extension Application {
    private struct PushNotificationSenderKey: StorageKey {
        typealias Value = any PushNotificationSending
    }

    var pushNotificationSender: any PushNotificationSending {
        get {
            guard let sender = storage[PushNotificationSenderKey.self] else {
                fatalError("PushNotificationSending not configured")
            }
            return sender
        }
        set {
            storage[PushNotificationSenderKey.self] = newValue
        }
    }
}
