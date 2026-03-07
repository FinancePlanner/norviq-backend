import Vapor

extension Application {
    struct UserProfileRepositoryKey: StorageKey {
        typealias Value = any UserProfileRepository
    }

    struct UserProfileServiceKey: StorageKey {
        typealias Value = any UserProfileService
    }

    var userProfileRepository: any UserProfileRepository {
        get { storage[UserProfileRepositoryKey.self]! }
        set { storage[UserProfileRepositoryKey.self] = newValue }
    }

    var userProfileService: any UserProfileService {
        get { storage[UserProfileServiceKey.self]! }
        set { storage[UserProfileServiceKey.self] = newValue }
    }
}
