import Foundation
@testable import StockPlanBackend
import Testing
import Vapor

@Suite("Discord webhook payload")
struct DiscordWebhookServiceTests {
    @Test("user text can't ping anyone: allowed_mentions parses nothing")
    func mentionsAreSuppressed() throws {
        var request = ClientRequest()
        try request.content.encode(DefaultDiscordWebhookService.payload("🚩 @everyone <@&123> look"))
        let body = try #require(request.body)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(body.readableBytesView)) as? [String: Any])
        #expect(json["content"] as? String == "🚩 @everyone <@&123> look")
        let mentions = try #require(json["allowed_mentions"] as? [String: Any])
        #expect((mentions["parse"] as? [Any])?.isEmpty == true)
    }
}
