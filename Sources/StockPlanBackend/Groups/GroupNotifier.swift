import Fluent
import Foundation
import RediStack
import StockPlanShared
import Vapor

/// Push for Groups. Fan-out runs detached on a request of its own, so a send
/// never waits on APNs and never touches the original request after it
/// returns.
enum GroupNotifier {
    /// One push per member per channel in this window; the rest of a burst
    /// lands in the same notification thread silently via the unread badge.
    static let throttleSeconds = 60

    /// Members with push on, except the author, people hidden from the
    /// author either way, and anyone pushed for this channel in the last minute.
    static func messageCreated(
        _ message: GroupMessage,
        groupName: String,
        channelName: String,
        authorUsername: String?,
        app: Application
    ) {
        Task {
            let req = Request(application: app, on: app.eventLoopGroup.next())
            do {
                let recipients = try await recipients(for: message, on: req)
                guard !recipients.isEmpty else { return }
                let push = GroupPushMessage(
                    kind: .message,
                    title: "\(groupName) · #\(channelName)",
                    body: "\(authorUsername.map { "@\($0)" } ?? "Someone"): \((message.body ?? "").prefix(140))",
                    groupId: message.groupId,
                    channelId: message.channelId,
                    messageId: message.id
                )
                for recipient in recipients {
                    if await claimThrottle(recipient, channelId: message.channelId, on: req) {
                        await send(push, to: recipient, on: req)
                    }
                }
            } catch {
                req.logger.warning("groups.push fan-out failed error=\(String(reflecting: type(of: error)))")
            }
        }
    }

    static func invited(_ userIds: [UUID], groupId: UUID, groupName: String, inviterUsername: String?, app: Application) {
        guard !userIds.isEmpty else { return }
        Task {
            let req = Request(application: app, on: app.eventLoopGroup.next())
            let push = GroupPushMessage(
                kind: .invite,
                title: "Group invite",
                body: "\(inviterUsername.map { "@\($0)" } ?? "A friend") invited you to \(groupName)",
                groupId: groupId,
                channelId: nil,
                messageId: nil
            )
            for userId in userIds {
                await send(push, to: userId, on: req)
            }
        }
    }

    static func recipients(for message: GroupMessage, on req: Request) async throws -> [UUID] {
        guard let author = message.authorId else { return [] }
        let hidden = try await SocialService.blockedEitherWay(for: author, on: req.db)
        return try await GroupMemberRecord.query(on: req.db)
            .filter(\.$groupId == message.groupId)
            .filter(\.$pushEnabled == true)
            .filter(\.$userId != author)
            .all()
            .map(\.userId)
            .filter { !hidden.contains($0) }
    }

    /// True when this member may be pushed for this channel now. Without
    /// Redis (local, tests) there is no throttle.
    static func claimThrottle(_ userId: UUID, channelId: UUID, on req: Request) async -> Bool {
        guard req.application.redis.configuration != nil else { return true }
        let key = RedisKey("push:gc:\(channelId.uuidString):\(userId.uuidString)")
        do {
            let result = try await req.redis.set(
                key, to: "1", onCondition: .keyDoesNotExist, expiration: .seconds(throttleSeconds)
            ).get()
            return result == .ok
        } catch {
            return true
        }
    }

    private static func send(_ message: GroupPushMessage, to userId: UUID, on req: Request) async {
        do {
            let devices = try await req.pushDeviceService.activeDevices(userId: userId, on: req.db)
            guard !devices.isEmpty else { return }
            _ = await req.application.pushNotificationSender.sendGroupEvent(message: message, devices: devices, req: req)
        } catch {
            req.logger.warning("groups.push failed kind=\(message.kind.rawValue) error=\(String(reflecting: type(of: error)))")
        }
    }
}
