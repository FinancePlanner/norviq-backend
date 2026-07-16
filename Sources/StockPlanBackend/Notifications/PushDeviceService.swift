import Fluent
import Foundation
import Vapor

protocol PushDeviceService: Sendable {
    func upsert(userId: UUID, payload: PushDeviceRegistrationRequest, on db: any Database) async throws -> PushDevice
    func deactivate(userId: UUID, deviceToken: String, on db: any Database) async throws
    func deactivate(deviceToken: String, on db: any Database) async throws
    func activeDevices(userId: UUID, on db: any Database) async throws -> [PushDevice]
}

struct DatabasePushDeviceService: PushDeviceService {
    func upsert(userId: UUID, payload: PushDeviceRegistrationRequest, on db: any Database) async throws -> PushDevice {
        let token = try normalizedDeviceToken(payload.deviceToken)
        let capabilitiesJSON = try encodedCapabilities(payload.capabilities)
        let now = Date()

        if let existing = try await PushDevice.query(on: db)
            .filter(\.$deviceToken == token)
            .first()
        {
            existing.userId = userId
            existing.platform = payload.platform.rawValue
            existing.apnsEnvironment = payload.apnsEnvironment.rawValue
            existing.authorizationStatus = payload.authorizationStatus.rawValue
            existing.capabilitiesJSON = capabilitiesJSON
            existing.isActive = true
            existing.lastSeenAt = now
            try await existing.save(on: db)
            return existing
        }

        let created = PushDevice(
            userId: userId,
            deviceToken: token,
            platform: payload.platform.rawValue,
            apnsEnvironment: payload.apnsEnvironment.rawValue,
            authorizationStatus: payload.authorizationStatus.rawValue,
            isActive: true,
            lastSeenAt: now,
            capabilitiesJSON: capabilitiesJSON
        )
        try await created.save(on: db)
        return created
    }

    func deactivate(userId: UUID, deviceToken: String, on db: any Database) async throws {
        let token = try normalizedDeviceToken(deviceToken)
        guard let model = try await PushDevice.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$deviceToken == token)
            .first()
        else {
            return
        }

        model.isActive = false
        model.lastSeenAt = Date()
        try await model.save(on: db)
    }

    func deactivate(deviceToken: String, on db: any Database) async throws {
        let token = try normalizedDeviceToken(deviceToken)
        guard let model = try await PushDevice.query(on: db)
            .filter(\.$deviceToken == token)
            .first()
        else {
            return
        }

        model.isActive = false
        model.lastSeenAt = Date()
        try await model.save(on: db)
    }

    func activeDevices(userId: UUID, on db: any Database) async throws -> [PushDevice] {
        try await PushDevice.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$isActive == true)
            .all()
    }

    private func normalizedDeviceToken(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "deviceToken is required.")
        }
        return trimmed
    }

    private func encodedCapabilities(_ capabilities: [String]?) throws -> String {
        let normalized = Array(Set((capabilities ?? []).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })).sorted()
        let data = try JSONEncoder().encode(normalized)
        guard let value = String(data: data, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Could not encode device capabilities.")
        }
        return value
    }
}

extension Application {
    private struct PushDeviceServiceKey: StorageKey {
        typealias Value = any PushDeviceService
    }

    var pushDeviceService: any PushDeviceService {
        get {
            guard let service = storage[PushDeviceServiceKey.self] else {
                fatalError("PushDeviceService not configured")
            }
            return service
        }
        set {
            storage[PushDeviceServiceKey.self] = newValue
        }
    }
}

extension Request {
    var pushDeviceService: any PushDeviceService {
        application.pushDeviceService
    }
}
