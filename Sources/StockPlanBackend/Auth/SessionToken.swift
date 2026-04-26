import Foundation
import JWT
import JWTKit
import Vapor

struct SessionToken: JWTPayload, Authenticatable {
    let userId: UUID
    let exp: ExpirationClaim

    func verify(using _: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }
}
