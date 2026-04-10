import APNS
import APNSCore
import Foundation
import Vapor
import VaporAPNS

struct TargetPushSendSummary: Sendable {
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
}

struct NoopPushNotificationSender: PushNotificationSending {
    func sendTargetHit(
        target: Target,
        currentPrice: Double,
        devices: [PushDevice],
        req: Request
    ) async -> TargetPushSendSummary {
        req.logger.debug(
            "push.notifications disabled symbol=\(target.symbol) scenario=\(target.scenario) devices=\(devices.count)"
        )
        return .init(delivered: 0, failed: devices.count)
    }
}

struct APNSPushNotificationSender: PushNotificationSending {
    struct Payload: Codable {
        let symbol: String
        let scenario: String
        let targetPrice: Double
        let currentPrice: Double
    }

    let topic: String

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
            symbol: target.symbol,
            scenario: target.scenario,
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
            payload: payload
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
                    "push.notifications send failed symbol=\(target.symbol) token=\(device.deviceToken) error=\(String(reflecting: error))"
                )
                if isInvalidTokenError(error) {
                    try? await req.pushDeviceService.deactivate(deviceToken: device.deviceToken, on: req.db)
                }
            }
        }

        return .init(delivered: delivered, failed: failed)
    }

    private func client(for device: PushDevice, req: Request) -> APNSGenericClient {
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
