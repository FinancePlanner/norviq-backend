import Foundation
import StockPlanShared
import Vapor

typealias PushAuthorizationStatus = StockPlanShared.PushAuthorizationStatus
typealias PushAPNSEnvironment = StockPlanShared.PushAPNSEnvironment
typealias PushPlatform = StockPlanShared.PushPlatform
typealias PushDeviceRegistrationRequest = StockPlanShared.PushDeviceRegistrationRequest
typealias PushDeviceRegistrationResponse = StockPlanShared.PushDeviceRegistrationResponse
typealias PushDeviceDeactivateRequest = StockPlanShared.PushDeviceDeactivateRequest

extension PushAuthorizationStatus: @retroactive Content {}
extension PushAPNSEnvironment: @retroactive Content {}
extension PushPlatform: @retroactive Content {}
extension PushDeviceRegistrationRequest: @retroactive Content {}
extension PushDeviceRegistrationResponse: @retroactive Content {}
extension PushDeviceDeactivateRequest: @retroactive Content {}

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
