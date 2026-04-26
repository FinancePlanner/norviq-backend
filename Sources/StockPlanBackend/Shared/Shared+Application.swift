import Vapor

extension Application {
    /// Stores the global idempotency middleware instance for route registration.
    /// Controllers access this to group mutation routes.
    var idempotencyMiddleware: IdempotencyMiddleware {
        get { storage[IdempotencyMiddlewareKey.self] ?? .init() }
        set { storage[IdempotencyMiddlewareKey.self] = newValue }
    }

    // MARK: - Data Export Services

    var dataExportRepository: any DataExportRepository {
        get { storage[DataExportRepositoryKey.self] ?? DatabaseDataExportRepository() }
        set { storage[DataExportRepositoryKey.self] = newValue }
    }

    var exportService: ExportService {
        get { storage[ExportServiceKey.self] ?? ExportService(repository: dataExportRepository, application: self) }
        set { storage[ExportServiceKey.self] = newValue }
    }

    var dataExportService: any DataExportService {
        get { storage[DataExportServiceKey.self] ?? DefaultDataExportService(repository: dataExportRepository, exporter: exportService) }
        set { storage[DataExportServiceKey.self] = newValue }
    }
}

private struct IdempotencyMiddlewareKey: StorageKey {
    typealias Value = IdempotencyMiddleware
}

private struct DataExportRepositoryKey: StorageKey {
    typealias Value = any DataExportRepository
}

private struct ExportServiceKey: StorageKey {
    typealias Value = ExportService
}

private struct DataExportServiceKey: StorageKey {
    typealias Value = any DataExportService
}
