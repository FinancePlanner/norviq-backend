import Vapor
import Foundation

struct TodoCreateRequest: Content {
    let title: String
}

struct TodoUpdateRequest: Content {
    let title: String
}

struct TodoResponse: Content {
    let id: UUID
    let title: String
    let createdAt: Date?
    let updatedAt: Date?

    init(from model: Todo) throws {
        self.id = try model.requireID()
        self.title = model.title
        self.createdAt = model.createdAt
        self.updatedAt = model.updatedAt
    }
}
