import Fluent
import Foundation
import NIOCore
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Screenshot import route", .serialized)
struct ScreenshotImportRouteTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            let previousOCR = getenv("RECEIPT_OCR_PROVIDER").map { String(cString: $0) }
            let previousBypass = getenv("BYPASS_BILLING").map { String(cString: $0) }
            setenv("RECEIPT_OCR_PROVIDER", "disabled", 1)
            setenv("BYPASS_BILLING", "false", 1)
            defer {
                restore("RECEIPT_OCR_PROVIDER", previousOCR)
                restore("BYPASS_BILLING", previousBypass)
            }

            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func restore(_ name: String, _ value: String?) {
        if let value {
            setenv(name, value, 1)
        } else {
            unsetenv(name)
        }
    }

    @Test("One JPEG posted as file gets past multipart decode")
    func singleFilePartIsNotADecodingError() async throws {
        try await withApp { app in
            let auth = try await register(on: app)
            try await Entitlement(userId: auth.userId, level: "pro").save(on: app.db)

            var multipart = MultipartBody(boundary: "B")
            multipart.addField(name: "provider", value: "manual")
            multipart.addFile(name: "file", filename: "shot.jpg", contentType: "image/jpeg", bytes: [0xFF, 0xD8, 0xFF, 0xD9])

            try await app.testing().test(.POST, "v1/brokers/import/screenshot?provider=manual", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                req.headers.replaceOrAdd(name: .contentType, value: multipart.contentType)
                req.body = multipart.finalized()
            }, afterResponse: { response async throws in
                let body = response.body.string
                // No extractor is configured in tests, so reaching it proves the upload was read.
                #expect(response.status == .serviceUnavailable, "status \(response.status) body \(body)")
                #expect(body.contains("Screenshot import is not available"))
            })
        }
    }

    @Test("Three screenshots over the app-wide 10 MB body cap still reach the handler")
    func threeLargeScreenshotsPassTheBodyCap() async throws {
        try await withApp { app in
            let auth = try await register(on: app)
            try await Entitlement(userId: auth.userId, level: "pro").save(on: app.db)

            var multipart = MultipartBody(boundary: "B")
            let fourMegabytes = [UInt8](repeating: 0x42, count: 4 * 1024 * 1024)
            for index in 1 ... 3 {
                multipart.addFile(name: "file", filename: "shot\(index).png", contentType: "image/png", bytes: fourMegabytes)
            }

            // A running server, because the in-memory tester skips the route's body cap.
            try await app.testing(method: .running(port: 0)).test(.POST, "v1/brokers/import/screenshot?provider=manual", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                req.headers.replaceOrAdd(name: .contentType, value: multipart.contentType)
                req.body = multipart.finalized()
            }, afterResponse: { response async throws in
                let body = response.body.string
                // No extractor is configured in tests, so reaching it proves the upload was read.
                #expect(response.status == .serviceUnavailable, "status \(response.status) body \(body)")
                #expect(body.contains("Screenshot import is not available"))
            })
        }
    }

    @Test("Receipt batch scan accepts repeated file parts")
    func receiptBatchReadsRepeatedFileParts() async throws {
        try await withApp { app in
            app.receiptOCRProvider = NothingRecognizedOCRProvider()
            let auth = try await register(on: app)
            try await Entitlement(userId: auth.userId, level: "pro").save(on: app.db)

            var multipart = MultipartBody(boundary: "B")
            multipart.addFile(name: "file", filename: "a.jpg", contentType: "image/jpeg", bytes: [0xFF, 0xD8, 0xFF, 0xD9])
            multipart.addFile(name: "file", filename: "b.jpg", contentType: "image/jpeg", bytes: [0xFF, 0xD8, 0xFF, 0xD9])

            try await app.testing().test(.POST, "v1/receipts/scan", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                req.headers.replaceOrAdd(name: .contentType, value: multipart.contentType)
                req.body = multipart.finalized()
            }, afterResponse: { response async throws in
                #expect(response.status == .ok, "status \(response.status) body \(response.body.string)")
                let decoded = try response.content.decode(ReceiptBatchScanResponse.self)
                #expect(decoded.results.count == 2)
            })
        }
    }

    private struct NothingRecognizedOCRProvider: ReceiptOCRProvider {
        var isEnabled: Bool {
            true
        }

        func extract(imageData _: Data, contentType _: String, on _: Request) async throws -> ReceiptDraft? {
            nil
        }
    }

    private func register(on app: Application) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "shot_import",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "shot-import@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var auth: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { response async throws in
            #expect(response.status == .ok)
            auth = try response.content.decode(AuthResponse.self)
        })
        let result = try #require(auth)
        let user = try #require(try await User.find(result.userId, on: app.db))
        user.trialStartedAt = nil
        user.trialDays = nil
        user.trialTier = nil
        try await user.save(on: app.db)
        return result
    }
}
