import Fluent
import struct Foundation.Date
import struct Foundation.UUID

/// Property wrappers interact poorly with `Sendable` checking, causing a warning for the `@ID` property
/// It is recommended you write your model with sendability checking on and then suppress the warning
/// afterwards with `@unchecked Sendable`.
final class Todo: Model, @unchecked Sendable {
    static let schema = "todos"
    
    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "title")
    var title: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(id: UUID? = nil, userId: UUID, title: String) {
        self.id = id
        self.userId = userId
        self.title = title
    }

    // MARK: - Active Record helpers (ownership-scoped)

    static func owned(by userId: UUID, on db: any Database) -> QueryBuilder<Todo> {
        Todo.query(on: db).filter(\.$userId == userId)
    }

    static func create(title: String, userId: UUID, on db: any Database) async throws -> Todo {
        let todo = Todo(userId: userId, title: title)
        try await todo.save(on: db)
        return todo
    }

    static func find(_ id: UUID, userId: UUID, on db: any Database) async throws -> Todo? {
        try await Todo.owned(by: userId, on: db)
            .filter(\.$id == id)
            .first()
    }
    
    func toDTO() -> TodoDTO {
        .init(
            id: self.id,
            title: self.title
        )
    }
}
