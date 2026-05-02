import APNS
import APNSCore
import Foundation
import Vapor
import VaporAPNS

struct TargetPushSendSummary {
    let delivered: Int
    let failed: Int
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
}

struct NoopPushNotificationSender: PushNotificationSending {
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
}

struct APNSPushNotificationSender: PushNotificationSending {
    private static let targetAlertCategoryID = "TARGET_ALERT"

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

    let topic: String

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
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
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
