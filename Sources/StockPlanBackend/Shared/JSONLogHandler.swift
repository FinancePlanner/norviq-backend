import Foundation
import Logging

struct JSONLogHandler: LogHandler {
    private static let lock = NSLock()

    let label: String
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level

    init(label: String, level: Logger.Level) {
        self.label = label
        self.logLevel = level
    }

    subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get { metadata[metadataKey] }
        set { metadata[metadataKey] = newValue }
    }

    func log(event: LogEvent) {
        guard event.level >= logLevel else { return }

        var payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "level": event.level.rawValue,
            "label": label,
            "message": event.message.description,
            "source": event.source,
            "file": URL(fileURLWithPath: event.file).lastPathComponent,
            "function": event.function,
            "line": event.line
        ]

        var mergedMetadata = metadata
        if let explicitMetadata = event.metadata {
            mergedMetadata.merge(explicitMetadata) { _, new in new }
        }
        if !mergedMetadata.isEmpty {
            payload["metadata"] = mergedMetadata.mapValues(Self.stringifyMetadata)
        }
        if let error = event.error {
            payload["error"] = String(reflecting: error)
        }

        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data("{\"level\":\"error\",\"message\":\"failed_to_encode_log\"}".utf8)
        Self.lock.lock()
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data("\n".utf8))
        Self.lock.unlock()
    }

    private static func stringifyMetadata(_ value: Logger.Metadata.Value) -> String {
        switch value {
        case .string(let string):
            return string
        case .stringConvertible(let value):
            return value.description
        case .array(let values):
            return "[" + values.map(stringifyMetadata).joined(separator: ",") + "]"
        case .dictionary(let dictionary):
            let rendered = dictionary
                .map { "\($0.key):\(stringifyMetadata($0.value))" }
                .sorted()
                .joined(separator: ",")
            return "{\(rendered)}"
        }
    }
}
