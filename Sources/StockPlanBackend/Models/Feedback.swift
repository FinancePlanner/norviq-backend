import Fluent
import Foundation
import Vapor

final class Feedback: Model, Content, @unchecked Sendable {
    static let schema = "feedbacks"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "topic")
    var topic: String

    @Field(key: "message")
    var message: String

    @Parent(key: "user_id")
    var user: User

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, topic: String, message: String, userID: User.IDValue) {
        self.id = id
        self.topic = topic
        self.message = message
        $user.id = userID
    }
}
