import Foundation
import StockPlanShared

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

extension JSONDecoder {
    static var backendAPI: JSONDecoder {
        let decoder = JSONDecoder.stockPlanShared
        decoder.keyDecodingStrategy = .custom { codingPath in
            guard let last = codingPath.last else {
                return AnyCodingKey(stringValue: "")!
            }

            let key = last.stringValue
            if key.contains("_") {
                return AnyCodingKey(stringValue: normalizeSnakeCaseKey(key))!
            }
            return AnyCodingKey(stringValue: key)!
        }
        return decoder
    }

    private static func normalizeSnakeCaseKey(_ key: String) -> String {
        let parts = key.split(separator: "_").map { String($0).lowercased() }
        guard let first = parts.first else { return key }

        var normalized = first
        for segment in parts.dropFirst() {
            if segment == "url" {
                normalized += "URL"
            } else if segment == "uri" {
                normalized += "URI"
            } else if segment == "id" {
                normalized += "Id"
            } else {
                normalized += segment.prefix(1).uppercased() + segment.dropFirst()
            }
        }
        return normalized
    }
}

extension JSONEncoder {
    static var backendAPI: JSONEncoder {
        let encoder = JSONEncoder.stockPlanShared
        encoder.keyEncodingStrategy = .useDefaultKeys
        return encoder
    }
}
