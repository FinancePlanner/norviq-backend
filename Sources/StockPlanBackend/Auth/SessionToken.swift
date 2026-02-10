import JWT
import JWTKit
import Vapor
import Foundation

struct SessionToken: JWTPayload, Authenticatable {
    let userId: UUID
    let exp: ExpirationClaim

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }
}
