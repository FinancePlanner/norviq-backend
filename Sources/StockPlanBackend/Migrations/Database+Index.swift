import Fluent
import FluentSQL

extension Database {
    func createIndex(
        on schema: String,
        columns: [String],
        name: String? = nil
    ) async throws {
        guard let sql = self as? SQLDatabase else { return }
        guard !columns.isEmpty else { return }

        let resolvedName = name ?? "idx_\(schema)_\(columns.joined(separator: "_"))"
        let builder = sql.create(index: resolvedName).on(schema)
        for column in columns {
            _ = builder.column(column)
        }
        try await builder.run()
    }
}
