import Vapor

// MARK: - /v1/market/congress/:symbol and /v1/market/congress/recent response

enum CongressChamber: String, Codable, Sendable {
    case senate
    case house
}

/// What the disclosure says the transaction was.
///
/// `other` covers everything the three named categories do not — receipts,
/// transfers, and rows that arrived with no type at all. It is never a guess.
enum CongressTradeType: String, Codable, Sendable {
    case purchase
    case sale
    case exchange
    case other
}

struct CongressTrade: Content, Equatable {
    let chamber: CongressChamber
    let politician: String
    /// Party as filed. Null when the disclosure feed does not carry one, which
    /// is the common case.
    let party: String?
    /// Two-letter state code, taken from the filing's state field or, failing
    /// that, from the leading two letters of a house district like `TX07`.
    let state: String?
    let symbol: String
    /// `yyyy-MM-dd`.
    let transactionDate: String
    /// `yyyy-MM-dd`. Empty when the filing carried no disclosure date.
    let disclosureDate: String
    let type: CongressTradeType
    /// The bracket exactly as disclosed, e.g. `$1,001 - $15,000`. Congressional
    /// disclosures report a range, never an amount.
    let amountRange: String
    /// Lower bound of `amountRange`. Null for an open-below bracket, or when
    /// the text carried no dollar figure.
    let amountMin: Double?
    /// Upper bound of `amountRange`. Null for an open-above bracket such as
    /// `Over $50,000,000`, or when the text carried no dollar figure.
    let amountMax: Double?
    let assetDescription: String?
    let link: String?
}

struct CongressTradesResponse: Content, Equatable {
    /// Both chambers merged, newest transaction first. Empty when there are no
    /// disclosures, or when the upstream plan does not cover them.
    let trades: [CongressTrade]
}

// MARK: - FMP wire model

/// A `/stable/senate-trades`, `/stable/house-trades`, `/stable/senate-latest`
/// or `/stable/house-latest` item. The four share a shape; which name fields
/// are populated varies by chamber and by endpoint, so all of them are
/// optional.
struct FMPCongressTrade: Codable, Sendable {
    let symbol: String?
    let disclosureDate: String?
    let transactionDate: String?
    let firstName: String?
    let lastName: String?
    let office: String?
    let district: String?
    let state: String?
    let party: String?
    let owner: String?
    let assetDescription: String?
    let assetType: String?
    let type: String?
    /// The disclosed bracket, e.g. `$1,001 - $15,000`.
    let amount: String?
    let link: String?
}

// MARK: - Configuration

enum CongressTradesConfig {
    static let defaultRecentLimit = 100
    static let recentLimitRange = 1 ... 200

    static func clampRecentLimit(_ requested: Int) -> Int {
        min(max(requested, recentLimitRange.lowerBound), recentLimitRange.upperBound)
    }

    static func redisKey(symbol: String) -> String {
        "market:congress:\(symbol)"
    }

    static func recentRedisKey(limit: Int) -> String {
        "market:congress:recent:\(limit)"
    }
}

// MARK: - Parsing

enum CongressTrades {
    /// Reads the numeric bounds out of a disclosed bracket.
    ///
    /// Two dollar figures are a closed range. One figure is read as a floor
    /// when the text says `over`/`more than`/`at least`, as a ceiling when it
    /// says `under`/`less than`/`below`, and as an exact amount otherwise. Text
    /// with no dollar figure yields no bounds rather than a zero.
    static func amountBounds(from raw: String?) -> (min: Double?, max: Double?) {
        guard let raw, raw.nonEmptyTrimmed != nil else { return (nil, nil) }
        let amounts = dollarAmounts(in: raw)
        let lowered = raw.lowercased()

        switch amounts.count {
        case 0:
            return (nil, nil)
        case 1:
            let value = amounts[0]
            if lowered.contains("over") || lowered.contains("more than") || lowered.contains("at least") {
                return (value, nil)
            }
            if lowered.contains("under") || lowered.contains("less than") || lowered.contains("below") {
                return (nil, value)
            }
            return (value, value)
        default:
            let pair = amounts.prefix(2).sorted()
            return (pair[0], pair[1])
        }
    }

    /// Reduces a disclosed transaction type to a category. Matched on
    /// substrings because the feeds report `Sale`, `Sale (Full)`,
    /// `Sale (Partial)` and `sale_partial` for the same thing.
    static func type(from raw: String?) -> CongressTradeType {
        guard let lowered = raw?.nonEmptyTrimmed?.lowercased() else { return .other }
        if lowered.contains("purchase") {
            return .purchase
        }
        if lowered.contains("sale") {
            return .sale
        }
        if lowered.contains("exchange") {
            return .exchange
        }
        return .other
    }

    /// Converts one upstream row. Nil when it has no symbol or no transaction
    /// date: the first is what the row is about and the second is what the list
    /// is ordered by, and neither can be invented.
    static func trade(from wire: FMPCongressTrade, chamber: CongressChamber) -> CongressTrade? {
        guard let symbol = wire.symbol?.nonEmptyTrimmed?.uppercased(),
              let transactionDate = wire.transactionDate?.nonEmptyTrimmed
        else { return nil }

        let amountRange = wire.amount?.nonEmptyTrimmed ?? ""
        let bounds = amountBounds(from: amountRange)

        return CongressTrade(
            chamber: chamber,
            politician: politician(from: wire),
            party: wire.party?.nonEmptyTrimmed,
            state: state(from: wire),
            symbol: symbol,
            transactionDate: transactionDate,
            disclosureDate: wire.disclosureDate?.nonEmptyTrimmed ?? "",
            type: type(from: wire.type),
            amountRange: amountRange,
            amountMin: bounds.min,
            amountMax: bounds.max,
            assetDescription: wire.assetDescription?.nonEmptyTrimmed,
            link: wire.link?.nonEmptyTrimmed
        )
    }

    /// Concatenates the chambers and orders the result newest transaction
    /// first, breaking ties on the disclosure date and then on politician and
    /// symbol so the order is the same on every call.
    static func merge(_ lists: [CongressTrade]...) -> [CongressTrade] {
        lists.flatMap(\.self).sorted { lhs, rhs in
            if lhs.transactionDate != rhs.transactionDate {
                return lhs.transactionDate > rhs.transactionDate
            }
            if lhs.disclosureDate != rhs.disclosureDate {
                return lhs.disclosureDate > rhs.disclosureDate
            }
            if lhs.politician != rhs.politician {
                return lhs.politician < rhs.politician
            }
            return lhs.symbol < rhs.symbol
        }
    }

    // MARK: - Private

    private static func politician(from wire: FMPCongressTrade) -> String {
        let parts = [wire.firstName?.nonEmptyTrimmed, wire.lastName?.nonEmptyTrimmed].compactMap(\.self)
        if !parts.isEmpty {
            return parts.joined(separator: " ")
        }
        return wire.office?.nonEmptyTrimmed ?? "Unknown"
    }

    /// The filing's own state field, or the leading state code of a house
    /// district (`TX07` → `TX`). A district that does not start with two
    /// letters leaves the state unknown rather than guessed.
    private static func state(from wire: FMPCongressTrade) -> String? {
        if let state = wire.state?.nonEmptyTrimmed {
            return state
        }
        guard let district = wire.district?.nonEmptyTrimmed, district.count >= 2 else { return nil }
        let prefix = district.prefix(2)
        guard prefix.allSatisfy(\.isLetter) else { return nil }
        return prefix.uppercased()
    }

    /// Every `$`-prefixed figure in `text`, in the order they appear, with
    /// thousands separators removed.
    private static func dollarAmounts(in text: String) -> [Double] {
        var amounts: [Double] = []
        var digits = ""
        var reading = false

        for character in text {
            if character == "$" {
                reading = true
                digits = ""
                continue
            }
            guard reading else { continue }
            if character.isNumber || character == "." {
                digits.append(character)
            } else if character == "," {
                continue
            } else {
                if let value = Double(digits) {
                    amounts.append(value)
                }
                reading = false
                digits = ""
            }
        }
        if reading, let value = Double(digits) {
            amounts.append(value)
        }
        return amounts
    }
}
