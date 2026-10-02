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

extension Application {
    struct CryptoMarketsServiceKey: StorageKey {
        typealias Value = any CryptoMarketsService
    }

    var cryptoMarketsService: any CryptoMarketsService {
        get { storage[CryptoMarketsServiceKey.self]! }
        set { storage[CryptoMarketsServiceKey.self] = newValue }
    }
}
