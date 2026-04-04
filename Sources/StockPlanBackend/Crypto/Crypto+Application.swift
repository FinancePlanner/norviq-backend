import Vapor

extension Application {
    struct CryptoServiceKey: StorageKey {
        typealias Value = any CryptoService
    }

    var cryptoService: any CryptoService {
        get { storage[CryptoServiceKey.self]! }
        set { storage[CryptoServiceKey.self] = newValue }
    }
}
