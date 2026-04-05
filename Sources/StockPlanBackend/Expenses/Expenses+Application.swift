import Vapor

extension Application {
    struct ExpensesServiceKey: StorageKey {
        typealias Value = any ExpensesService
    }

    var expensesService: any ExpensesService {
        get { storage[ExpensesServiceKey.self]! }
        set { storage[ExpensesServiceKey.self] = newValue }
    }
}
