import Vapor

extension Application {
    struct BrokersRepositoryKey: StorageKey {
        typealias Value = any BrokersRepository
    }

    struct BrokersServiceKey: StorageKey {
        typealias Value = any BrokersService
    }

    var brokersRepository: any BrokersRepository {
        get { storage[BrokersRepositoryKey.self]! }
        set { storage[BrokersRepositoryKey.self] = newValue }
    }

    var brokersService: any BrokersService {
        get { storage[BrokersServiceKey.self]! }
        set { storage[BrokersServiceKey.self] = newValue }
    }
}

