import Foundation
import Vapor

struct AuthRegisterRequest: Content, Equatable {
    let username: String
    let password: String
    let email: String
    let firstName: String
    let lastName: String
    let dateOfBirth: Date

    private enum CodingKeys: String, CodingKey {
        case username
        case password
        case email
        case firstName
        case lastName
        case dateOfBirth
    }

    init(
        username: String,
        password: String,
        email: String,
        firstName: String,
        lastName: String,
        dateOfBirth: Date
    ) {
        self.username = username
        self.password = password
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.dateOfBirth = dateOfBirth
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decode(String.self, forKey: .username)
        password = try container.decode(String.self, forKey: .password)
        email = try container.decode(String.self, forKey: .email)
        firstName = try container.decode(String.self, forKey: .firstName)
        lastName = try container.decode(String.self, forKey: .lastName)
        dateOfBirth = try Self.decodeDateOfBirth(from: container)
    }

    private static func decodeDateOfBirth(from container: KeyedDecodingContainer<CodingKeys>) throws -> Date {
        if let date = try? container.decode(Date.self, forKey: .dateOfBirth) {
            return date
        }

        if let stringValue = try? container.decode(String.self, forKey: .dateOfBirth) {
            let withFractionalSeconds = ISO8601DateFormatter()
            withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = withFractionalSeconds.date(from: stringValue) {
                return parsed
            }

            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let parsed = standard.date(from: stringValue) {
                return parsed
            }

            if let referenceSeconds = Double(stringValue) {
                return Date(timeIntervalSinceReferenceDate: referenceSeconds)
            }
        }

        if let referenceSeconds = try? container.decode(Double.self, forKey: .dateOfBirth) {
            // JSONEncoder's default Date strategy uses seconds since 2001-01-01.
            return Date(timeIntervalSinceReferenceDate: referenceSeconds)
        }

        if let referenceSeconds = try? container.decode(Int.self, forKey: .dateOfBirth) {
            return Date(timeIntervalSinceReferenceDate: Double(referenceSeconds))
        }

        throw DecodingError.typeMismatch(
            Date.self,
            .init(
                codingPath: container.codingPath + [CodingKeys.dateOfBirth],
                debugDescription: "dateOfBirth must be an ISO8601 string or seconds since Apple reference date"
            )
        )
    }
}

struct AuthLoginRequest: Content, Equatable {
    let email: String
    let password: String
}

struct AuthResponse: Content, Equatable {
    let token: String
    let userId: UUID
    let expiresIn: Int
    let refreshToken: String
    let refreshExpiresIn: Int
    let username: String
    let email: String
    let firstName: String
    let lastName: String
    let dateOfBirth: Date
}

typealias AuthRegisterResponse = AuthResponse

struct AuthUserResponse: Content, Equatable {
    let id: String
    let username: String
    let email: String
    let firstName: String
    let lastName: String
    let dateOfBirth: Date
}

struct AuthForgotPasswordRequest: Content, Equatable {
    let email: String
}

struct AuthForgotPasswordResponse: Content, Equatable {
    let message: String
    let resetCode: String?
}

struct AuthResetPasswordRequest: Content, Equatable {
    let email: String
    let code: String
    let newPassword: String
}

struct AuthRefreshRequest: Content, Equatable {
    let refreshToken: String
}
