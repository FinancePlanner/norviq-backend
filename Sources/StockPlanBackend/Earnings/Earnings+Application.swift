import Vapor

extension Application {
    struct EarningsServiceKey: StorageKey {
        typealias Value = any EarningsService
    }

    var earningsService: any EarningsService {
        get { storage[EarningsServiceKey.self]! }
        set { storage[EarningsServiceKey.self] = newValue }
    }
}
