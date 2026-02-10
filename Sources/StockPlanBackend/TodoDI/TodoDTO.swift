import Fluent
import Vapor

struct TodoDTO: Content {
    var id: UUID?
    var title: String
    
    func toModel(userId: UUID) -> Todo {
        let model = Todo(userId: userId, title: self.title)
        model.id = self.id
        return model
    }
}
