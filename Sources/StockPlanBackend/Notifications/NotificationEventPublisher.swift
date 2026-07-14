import Fluent
import Foundation
import StockPlanShared
import Vapor

enum NotificationEventPublisher {
    @discardableResult
    static func publishAndPush(
        userId: UUID,
        kind: NotificationEventKind,
        deduplicationKey: String,
        title: String,
        body: String,
        deepLink: String? = nil,
        payload: [String: String] = [:],
        req: Request
    ) async throws -> NotificationEventModel {
        let event = try await publish(
            userId: userId,
            kind: kind,
            deduplicationKey: deduplicationKey,
            title: title,
            body: body,
            deepLink: deepLink,
            payload: payload,
            on: req.db
        )
        guard let eventId = event.id else { return event }
        let existingDelivery = try await NotificationDeliveryModel.query(on: req.db)
            .filter(\.$event.$id == eventId)
            .filter(\.$channel == "apns")
            .first()
        let delivery: NotificationDeliveryModel
        if let existingDelivery {
            guard existingDelivery.status != "delivered",
                  existingDelivery.status != "no_devices",
                  existingDelivery.status != "pending"
            else {
                return event
            }
            delivery = existingDelivery
            delivery.status = "pending"
            delivery.attemptCount += 1
            delivery.lastError = nil
            try await delivery.update(on: req.db)
        } else {
            delivery = NotificationDeliveryModel()
            delivery.$event.id = eventId
            delivery.channel = "apns"
            delivery.status = "pending"
            delivery.attemptCount = 1
            delivery.lastError = nil
            do {
                try await delivery.create(on: req.db)
            } catch {
                // The unique (event, channel) index is the final concurrency guard.
                // If another publisher created the claim, it owns this send attempt.
                if try await NotificationDeliveryModel.query(on: req.db)
                    .filter(\.$event.$id == eventId)
                    .filter(\.$channel == "apns")
                    .first() != nil
                {
                    return event
                }
                throw error
            }
        }
        do {
            let devices = try await req.pushDeviceService.activeDevices(userId: userId, on: req.db)
            guard devices.isEmpty == false else {
                delivery.status = "no_devices"
                try await delivery.update(on: req.db)
                return event
            }
            let summary = await req.application.pushNotificationSender.sendAutomationAlert(
                message: AutomationPushMessage(
                    eventId: eventId,
                    kind: kind,
                    title: title,
                    body: body,
                    deepLink: deepLink,
                    payload: payload
                ),
                devices: devices,
                req: req
            )
            delivery.status = summary.delivered > 0 ? "delivered" : "failed"
            delivery.lastError = summary.failed > 0 ? "Failed deliveries: \(summary.failed)" : nil
            try await delivery.update(on: req.db)
        } catch {
            delivery.status = "failed"
            delivery.lastError = String(reflecting: type(of: error))
            try? await delivery.update(on: req.db)
            req.logger.warning(
                "automation push delivery failed event_id=\(eventId) error_type=\(String(reflecting: type(of: error)))"
            )
        }
        return event
    }

    @discardableResult
    static func publish(
        userId: UUID,
        kind: NotificationEventKind,
        deduplicationKey: String,
        title: String,
        body: String,
        deepLink: String? = nil,
        payload: [String: String] = [:],
        on db: any Database
    ) async throws -> NotificationEventModel {
        if let existing = try await NotificationEventModel.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$deduplicationKey == deduplicationKey)
            .first()
        {
            return existing
        }
        let event = NotificationEventModel(
            userId: userId,
            kind: kind,
            deduplicationKey: deduplicationKey,
            title: title,
            body: body,
            deepLink: deepLink,
            payload: payload
        )
        do {
            try await event.create(on: db)
            return event
        } catch {
            if let existing = try await NotificationEventModel.query(on: db)
                .filter(\.$userId == userId)
                .filter(\.$deduplicationKey == deduplicationKey)
                .first()
            {
                return existing
            }
            throw error
        }
    }
}
