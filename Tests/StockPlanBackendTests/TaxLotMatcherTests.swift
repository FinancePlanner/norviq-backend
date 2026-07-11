import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Tax lot matcher")
struct TaxLotMatcherTests {
    private let matcher = TaxLotMatcher()
    private let olderID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let newerID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test
    func `FIFO consumes the oldest lot and supports a partial second lot`() throws {
        let matches = try matcher.match(
            candidates: candidates,
            quantity: 12,
            unitPrice: 20,
            fees: 12,
            method: .fifo
        )
        #expect(matches.map(\.lotId) == [olderID, newerID])
        #expect(matches.map(\.quantity) == [10, 2])
        #expect(matches.reduce(0) { $0 + $1.proceeds } == 228)
        #expect(matches.reduce(0) { $0 + $1.costBasis } == 124)
    }

    @Test
    func `LIFO consumes the newest lot first`() throws {
        let matches = try matcher.match(
            candidates: candidates,
            quantity: 6,
            unitPrice: 20,
            fees: 0,
            method: .lifo
        )
        #expect(matches.map(\.lotId) == [newerID])
        #expect(matches[0].costBasis == 72)
    }

    @Test
    func `Specific ID follows broker-confirmed lot order`() throws {
        let matches = try matcher.match(
            candidates: candidates,
            quantity: 11,
            unitPrice: 20,
            fees: 0,
            method: .specificID,
            specificLotIDs: [newerID, olderID]
        )
        #expect(matches.map(\.lotId) == [newerID, olderID])
        #expect(matches.map(\.quantity) == [8, 3])
    }

    @Test
    func `Specific ID fails closed when identifiers are absent`() {
        #expect(throws: TaxLotAccountingError.self) {
            try matcher.match(candidates: candidates, quantity: 1, unitPrice: 20, fees: 0, method: .specificID)
        }
    }

    private var candidates: [TaxLotCandidate] {
        [
            .init(id: newerID, openDate: Date(timeIntervalSince1970: 200), remainingQuantity: 8, unitBasis: 12),
            .init(id: olderID, openDate: Date(timeIntervalSince1970: 100), remainingQuantity: 10, unitBasis: 10),
        ]
    }
}

@Suite("Tax wash-sale matcher")
struct TaxWashSaleMatcherTests {
    private let matcher = TaxWashSaleMatcher()
    private let saleDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `allocates disallowed loss by replacement quantity inside the window`() {
        let inside = UUID()
        let allocations = matcher.match(
            saleDate: saleDate,
            soldQuantity: 10,
            realizedPnL: -1000,
            replacements: [
                .init(lotId: UUID(), acquisitionDate: saleDate.addingTimeInterval(-31 * 86400), availableQuantity: 10, isTaxAdvantaged: false),
                .init(lotId: inside, acquisitionDate: saleDate.addingTimeInterval(5 * 86400), availableQuantity: 4, isTaxAdvantaged: false),
            ]
        )
        #expect(allocations == [.init(replacementLotId: inside, matchedQuantity: 4, disallowedLoss: 400, isPermanent: false)])
    }

    @Test
    func `caps matching at disposed quantity and marks retirement replacements permanent`() throws {
        let first = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000010"))
        let second = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000011"))
        let allocations = matcher.match(
            saleDate: saleDate,
            soldQuantity: 5,
            realizedPnL: -250,
            replacements: [
                .init(lotId: first, acquisitionDate: saleDate, availableQuantity: 3, isTaxAdvantaged: true),
                .init(lotId: second, acquisitionDate: saleDate.addingTimeInterval(86400), availableQuantity: 8, isTaxAdvantaged: false),
            ]
        )
        #expect(allocations.map(\.matchedQuantity) == [3, 2])
        #expect(allocations.map(\.disallowedLoss) == [150, 100])
        #expect(allocations.map(\.isPermanent) == [true, false])
    }

    @Test
    func `does not match gains`() {
        #expect(matcher.match(
            saleDate: saleDate,
            soldQuantity: 5,
            realizedPnL: 100,
            replacements: [.init(lotId: UUID(), acquisitionDate: saleDate, availableQuantity: 5, isTaxAdvantaged: false)]
        ).isEmpty)
    }
}

@Suite("Tax notification policy")
struct TaxNotificationPolicyTests {
    private let policy = TaxNotificationPolicy()

    @Test
    func `uses the greatest of absolute portfolio and configured thresholds`() {
        #expect(policy.threshold(taxablePortfolioValue: 10000, configuredMinimum: nil) == 250)
        #expect(policy.threshold(taxablePortfolioValue: 100_000, configuredMinimum: nil) == 500)
        #expect(policy.threshold(taxablePortfolioValue: 100_000, configuredMinimum: 750) == 750)
    }

    @Test
    func `cooldown override requires a twenty five percent improvement`() {
        #expect(!policy.shouldNotify(benefit: 499, threshold: 500, previousBenefit: nil))
        #expect(policy.shouldNotify(benefit: 500, threshold: 500, previousBenefit: nil))
        #expect(!policy.shouldNotify(benefit: 624, threshold: 500, previousBenefit: 500))
        #expect(policy.shouldNotify(benefit: 625, threshold: 500, previousBenefit: 500))
    }
}
