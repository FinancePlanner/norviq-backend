import Foundation

/// Loosely-typed tool arguments as a model produces them.
///
/// Models are inconsistent about JSON types — a number arrives as `12`, `12.0`
/// or `"12"` depending on the provider and the phrasing — so every accessor
/// coerces rather than pattern-matching one representation. These helpers were
/// duplicated across the tool registries before the catalog existed.
/// `@unchecked` because the decoded JSON is `[String: Any]`, which the compiler
/// cannot prove Sendable. The dictionary is assigned once in `init` and never
/// mutated or handed out, so it is effectively immutable — but that is an
/// invariant of this file, not something the type system enforces here.
struct ActionArguments: @unchecked Sendable {
    private let raw: [String: Any]

    init(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            raw = [:]
            return
        }
        raw = object
    }

    init(_ raw: [String: Any]) {
        self.raw = raw
    }

    func string(_ key: String) -> String? {
        guard let value = raw[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    func double(_ key: String) -> Double? {
        switch raw[key] {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as String: Double(value)
        default: nil
        }
    }

    func int(_ key: String) -> Int? {
        switch raw[key] {
        case let value as Int: value
        case let value as Double: Int(value)
        case let value as String: Int(value)
        default: nil
        }
    }

    func bool(_ key: String) -> Bool? {
        switch raw[key] {
        case let value as Bool: value
        case let value as String: value == "true"
        default: nil
        }
    }

    func uuid(_ key: String) -> UUID? {
        string(key).flatMap(UUID.init(uuidString:))
    }

    /// Array of objects, for batch actions.
    func objects(_ key: String) -> [ActionArguments] {
        guard let items = raw[key] as? [[String: Any]] else { return [] }
        return items.map(ActionArguments.init)
    }
}
