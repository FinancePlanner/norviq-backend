@testable import StockPlanBackend
import Testing

@Suite("Congressional trades")
struct CongressTradesTests {
    // MARK: - Fixtures

    private func wire(
        symbol: String = "AAPL",
        transactionDate: String = "2026-06-01",
        disclosureDate: String = "2026-06-20",
        firstName: String? = "Ann",
        lastName: String? = "Alpha",
        type: String = "Purchase",
        amount: String = "$1,001 - $15,000",
        state: String? = nil,
        district: String? = nil,
        party: String? = nil,
        office: String? = nil
    ) -> FMPCongressTrade {
        FMPCongressTrade(
            symbol: symbol,
            disclosureDate: disclosureDate,
            transactionDate: transactionDate,
            firstName: firstName,
            lastName: lastName,
            office: office,
            district: district,
            state: state,
            party: party,
            owner: nil,
            assetDescription: "Apple Inc. Common Stock",
            assetType: "Stock",
            type: type,
            amount: amount,
            link: "https://disclosures.example/1"
        )
    }

    private func trade(_ wire: FMPCongressTrade, _ chamber: CongressChamber = .senate) throws -> CongressTrade {
        try #require(CongressTrades.trade(from: wire, chamber: chamber))
    }

    // MARK: - Amount-range parsing

    @Test("A two-sided dollar range parses into both bounds")
    func twoSidedRangeParses() {
        let bounds = CongressTrades.amountBounds(from: "$1,001 - $15,000")

        #expect(bounds.min == 1001)
        #expect(bounds.max == 15000)
    }

    @Test("An open-ended `Over` range has a floor and no ceiling")
    func openEndedRangeHasNoCeiling() {
        let bounds = CongressTrades.amountBounds(from: "Over $50,000,000")

        #expect(bounds.min == 50_000_000)
        #expect(bounds.max == nil)
    }

    @Test("An `Under` range has a ceiling and no floor")
    func underRangeHasNoFloor() {
        let bounds = CongressTrades.amountBounds(from: "Under $1,001")

        #expect(bounds.min == nil)
        #expect(bounds.max == 1001)
    }

    @Test("A single exact amount is both bounds")
    func singleAmountIsBothBounds() {
        let bounds = CongressTrades.amountBounds(from: "$15,000")

        #expect(bounds.min == 15000)
        #expect(bounds.max == 15000)
    }

    @Test("An en dash separates a range just as a hyphen does")
    func enDashSeparatesARange() {
        let bounds = CongressTrades.amountBounds(from: "$1,001 – $15,000")

        #expect(bounds.min == 1001)
        #expect(bounds.max == 15000)
    }

    @Test(
        "Text with no dollar amount yields no bounds",
        arguments: [nil, "", "   ", "Unknown", "--"]
    )
    func unparseableTextYieldsNoBounds(raw: String?) {
        let bounds = CongressTrades.amountBounds(from: raw)

        #expect(bounds.min == nil)
        #expect(bounds.max == nil)
    }

    @Test("The raw range string is preserved next to the parsed bounds")
    func rawRangeIsPreserved() throws {
        let parsed = try trade(wire(amount: "$1,001 - $15,000"))

        #expect(parsed.amountRange == "$1,001 - $15,000")
        #expect(parsed.amountMin == 1001)
        #expect(parsed.amountMax == 15000)
    }

    // MARK: - Type mapping

    @Test(
        "Disclosure type strings map to purchase, sale, exchange, or other",
        arguments: [
            ("Purchase", CongressTradeType.purchase),
            ("purchase", CongressTradeType.purchase),
            ("Sale", CongressTradeType.sale),
            ("Sale (Full)", CongressTradeType.sale),
            ("Sale (Partial)", CongressTradeType.sale),
            ("sale_partial", CongressTradeType.sale),
            ("Exchange", CongressTradeType.exchange),
            ("Receive", CongressTradeType.other),
            ("", CongressTradeType.other),
        ]
    )
    func typeStringsMap(raw: String, expected: CongressTradeType) {
        #expect(CongressTrades.type(from: raw) == expected)
    }

    @Test("A missing disclosure type is `other`, not a guess")
    func missingTypeIsOther() {
        #expect(CongressTrades.type(from: nil) == .other)
    }

    // MARK: - Merge and sort

    @Test("Both chambers merge into one list, newest transaction first")
    func chambersMergeNewestFirst() throws {
        let senate = try [
            trade(wire(symbol: "AAPL", transactionDate: "2026-05-01"), .senate),
            trade(wire(symbol: "MSFT", transactionDate: "2026-06-10"), .senate),
        ]
        let house = try [
            trade(wire(symbol: "NVDA", transactionDate: "2026-06-20"), .house),
            trade(wire(symbol: "TSLA", transactionDate: "2026-04-02"), .house),
        ]

        let merged = CongressTrades.merge(senate, house)

        #expect(merged.map(\.symbol) == ["NVDA", "MSFT", "AAPL", "TSLA"])
        #expect(merged.map(\.chamber) == [.house, .senate, .senate, .house])
    }

    @Test("Merging an empty chamber with a populated one keeps the populated one")
    func mergingWithAnEmptyChamberKeepsTheOther() throws {
        let senate = try [trade(wire(symbol: "AAPL"), .senate)]

        #expect(CongressTrades.merge(senate, []).map(\.symbol) == ["AAPL"])
        #expect(CongressTrades.merge([], []).isEmpty)
    }

    @Test("Same-day trades fall back to the disclosure date, newest first")
    func sameDayTradesTieBreakOnDisclosure() throws {
        let trades = try [
            trade(wire(symbol: "AAPL", transactionDate: "2026-06-01", disclosureDate: "2026-06-10")),
            trade(wire(symbol: "MSFT", transactionDate: "2026-06-01", disclosureDate: "2026-06-25")),
        ]

        #expect(CongressTrades.merge(trades).map(\.symbol) == ["MSFT", "AAPL"])
    }

    // MARK: - Politician, party, state

    @Test("The politician is the first and last name joined")
    func politicianIsTheJoinedName() throws {
        let parsed = try trade(wire(firstName: "Ann", lastName: "Alpha"))

        #expect(parsed.politician == "Ann Alpha")
    }

    @Test("Without a first/last name the office field names the politician")
    func officeNamesThePoliticianWhenNamePartsAreMissing() throws {
        let parsed = try trade(wire(firstName: nil, lastName: nil, office: "Bob Beta"))

        #expect(parsed.politician == "Bob Beta")
    }

    @Test("Party and state pass through when the filing carries them")
    func partyAndStatePassThrough() throws {
        let parsed = try trade(wire(state: "TX", party: "Republican"))

        #expect(parsed.party == "Republican")
        #expect(parsed.state == "TX")
    }

    @Test("A house district supplies the state when no state field is present")
    func districtSuppliesTheState() throws {
        let parsed = try trade(wire(state: nil, district: "TX07"), .house)

        #expect(parsed.state == "TX")
    }

    @Test("A district that is not a state code leaves the state unknown")
    func nonStateDistrictLeavesStateNil() throws {
        let parsed = try trade(wire(state: nil, district: "07"), .house)

        #expect(parsed.state == nil)
    }

    // MARK: - Unusable rows

    @Test("A row with no symbol is dropped rather than published without one")
    func rowsWithoutASymbolAreDropped() {
        #expect(CongressTrades.trade(from: wire(symbol: ""), chamber: .senate) == nil)
    }

    @Test("A row with no transaction date is dropped, because the list sorts on it")
    func rowsWithoutATransactionDateAreDropped() {
        #expect(CongressTrades.trade(from: wire(transactionDate: ""), chamber: .senate) == nil)
    }
}
