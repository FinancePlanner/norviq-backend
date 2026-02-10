import Foundation

enum BrokerProvider {
    static func normalize(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BrokersServiceError.invalidProvider
        }

        let lowercased = trimmed.lowercased()

        let allowedAlphaNum = CharacterSet.alphanumerics
        var out = ""
        out.reserveCapacity(lowercased.count)
        var wroteDash = false

        for scalar in lowercased.unicodeScalars {
            if allowedAlphaNum.contains(scalar) {
                out.unicodeScalars.append(scalar)
                wroteDash = false
                continue
            }

            if scalar == "_" {
                out.append("_")
                wroteDash = false
                continue
            }

            if !wroteDash {
                out.append("-")
                wroteDash = true
            }
        }

        let normalized = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !normalized.isEmpty, normalized.count <= 64 else {
            throw BrokersServiceError.invalidProvider
        }

        return normalized
    }
}

