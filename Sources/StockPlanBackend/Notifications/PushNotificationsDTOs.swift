import Foundation
import Vapor

enum PushAuthorizationStatus: String, Codable, CaseIterable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
}

enum PushAPNSEnvironment: String, Codable, CaseIterable, Sendable {
    case development
    case production
}

enum PushPlatform: String, Codable, CaseIterable, Sendable {
    case ios
}

struct PushDeviceRegistrationRequest: Content, Sendable {
    let deviceToken: String
    let platform: PushPlatform
    let apnsEnvironment: PushAPNSEnvironment
    let authorizationStatus: PushAuthorizationStatus
}

struct PushDeviceRegistrationResponse: Content, Sendable {
    let id: String
    let deviceToken: String
    let platform: PushPlatform
    let apnsEnvironment: PushAPNSEnvironment
    let authorizationStatus: PushAuthorizationStatus
    let isActive: Bool
    let lastSeenAt: String
}

struct PushDeviceDeactivateRequest: Content, Sendable {
    let deviceToken: String
}

extension PushDeviceRegistrationResponse {
    init(from model: PushDevice) throws {
        guard let id = model.id else {
            throw Abort(.internalServerError, reason: "Push device id missing.")
        }
        guard let platform = PushPlatform(rawValue: model.platform) else {
            throw Abort(.internalServerError, reason: "Push device platform invalid.")
        }
        guard let apnsEnvironment = PushAPNSEnvironment(rawValue: model.apnsEnvironment) else {
            throw Abort(.internalServerError, reason: "Push device APNS environment invalid.")
        }
        guard let authorizationStatus = PushAuthorizationStatus(rawValue: model.authorizationStatus) else {
            throw Abort(.internalServerError, reason: "Push device authorization status invalid.")
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        self = .init(
            id: id.uuidString,
            deviceToken: model.deviceToken,
            platform: platform,
            apnsEnvironment: apnsEnvironment,
            authorizationStatus: authorizationStatus,
            isActive: model.isActive,
            lastSeenAt: formatter.string(from: model.lastSeenAt)
        )
    }
}
