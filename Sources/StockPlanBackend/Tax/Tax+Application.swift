import Vapor

extension Application {
    private struct TaxServiceKey: StorageKey {
        typealias Value = any TaxService
    }

    var taxService: any TaxService {
        get { storage[TaxServiceKey.self]! }
        set { storage[TaxServiceKey.self] = newValue }
    }
}
