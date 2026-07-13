import Foundation

struct SimpleXLSXWriter: Sendable {
    func makeWorkbook(_ document: ReportDocument) -> Data {
        let summaryRows = document.portfolios.enumerated().map { index, portfolio in
            let row = index + 4
            return rowXML(row, [
                textCell("A\(row)", portfolio.name),
                textCell("B\(row)", portfolio.currency),
                numberCell("C\(row)", portfolio.investedValue),
                numberCell("D\(row)", portfolio.cash),
                formulaCell("E\(row)", "SUM(C\(row):D\(row))", cached: portfolio.totalValue),
                numberCell("F\(row)", Double(portfolio.holdings.count)),
            ])
        }.joined()
        var holdingRows = ""
        var holdingRow = 3
        for portfolio in document.portfolios {
            for holding in portfolio.holdings {
                holdingRows += rowXML(holdingRow, [
                    textCell("A\(holdingRow)", portfolio.name),
                    textCell("B\(holdingRow)", holding.symbol),
                    textCell("C\(holdingRow)", holding.category),
                    numberCell("D\(holdingRow)", holding.shares),
                    numberCell("E\(holdingRow)", holding.price),
                    formulaCell("F\(holdingRow)", "D\(holdingRow)*E\(holdingRow)", cached: holding.value),
                ])
                holdingRow += 1
            }
        }
        let generated = ISO8601DateFormatter().string(from: document.generatedAt)
        let entries: [(String, Data)] = [
            ("[Content_Types].xml", data(contentTypes)),
            ("_rels/.rels", data(rootRelationships)),
            ("docProps/core.xml", data(coreProperties(title: document.title, generated: generated))),
            ("docProps/app.xml", data(appProperties)),
            ("xl/workbook.xml", data(workbook)),
            ("xl/_rels/workbook.xml.rels", data(workbookRelationships)),
            ("xl/styles.xml", data(styles)),
            ("xl/worksheets/sheet1.xml", data(sheet(
                columns: "<cols><col min=\"1\" max=\"1\" width=\"28\" customWidth=\"1\"/><col min=\"2\" max=\"2\" width=\"12\" customWidth=\"1\"/><col min=\"3\" max=\"6\" width=\"18\" customWidth=\"1\"/></cols>",
                rows: rowXML(1, [textCell("A1", document.title, style: 2)])
                    + rowXML(2, [textCell("A2", "Generated \(generated)", style: 3)])
                    + rowXML(3, ["Portfolio", "Currency", "Invested", "Cash", "Total", "Holdings"].enumerated().map { textCell("\(column($0.offset + 1))3", $0.element, style: 1) })
                    + summaryRows
            ))),
            ("xl/worksheets/sheet2.xml", data(sheet(
                columns: "<cols><col min=\"1\" max=\"3\" width=\"22\" customWidth=\"1\"/><col min=\"4\" max=\"6\" width=\"16\" customWidth=\"1\"/></cols>",
                rows: rowXML(1, [textCell("A1", "Holdings", style: 2)])
                    + rowXML(2, ["Portfolio", "Symbol", "Asset class", "Shares", "Price", "Value"].enumerated().map { textCell("\(column($0.offset + 1))2", $0.element, style: 1) })
                    + holdingRows
            ))),
            ("xl/worksheets/sheet3.xml", data(sheet(
                columns: "<cols><col min=\"1\" max=\"1\" width=\"110\" customWidth=\"1\"/></cols>",
                rows: rowXML(1, [textCell("A1", "Assumptions and disclosures", style: 2)])
                    + rowXML(3, [textCell("A3", "Values reflect available portfolio records and user-entered assumptions at generation time.")])
                    + rowXML(4, [textCell("A4", "This workbook is educational information, not individualized tax, legal, or investment advice.")])
            ))),
        ]
        return StoredZipArchive(entries: entries).data()
    }

    private func sheet(columns: String, rows: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\(columns)<sheetData>\(rows)</sheetData></worksheet>"
    }

    private func rowXML(_ row: Int, _ cells: [String]) -> String {
        "<row r=\"\(row)\">\(cells.joined())</row>"
    }

    private func textCell(_ reference: String, _ value: String, style: Int = 0) -> String {
        "<c r=\"\(reference)\" s=\"\(style)\" t=\"inlineStr\"><is><t>\(xml(value))</t></is></c>"
    }

    private func numberCell(_ reference: String, _ value: Double) -> String {
        "<c r=\"\(reference)\" s=\"4\"><v>\(value)</v></c>"
    }

    private func formulaCell(_ reference: String, _ formula: String, cached: Double) -> String {
        "<c r=\"\(reference)\" s=\"4\"><f>\(formula)</f><v>\(cached)</v></c>"
    }

    private func column(_ value: Int) -> String {
        String(UnicodeScalar(64 + value)!)
    }

    private func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func data(_ value: String) -> Data {
        Data(value.utf8)
    }

    private var contentTypes: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet3.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
        """
    }

    private var rootRelationships: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
        """
    }

    private var workbook: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><calcPr calcMode="auto"/><sheets><sheet name="Summary" sheetId="1" r:id="rId1"/><sheet name="Holdings" sheetId="2" r:id="rId2"/><sheet name="Assumptions" sheetId="3" r:id="rId3"/></sheets></workbook>
        """
    }

    private var workbookRelationships: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet3.xml"/><Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """
    }

    private var styles: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00"/></numFmts><fonts count="3"><font><sz val="11"/><name val="Aptos"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Aptos"/></font><font><b/><color rgb="FF173D28"/><sz val="18"/><name val="Aptos Display"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF315C42"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="5"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/><xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"><alignment wrapText="1"/></xf><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs></styleSheet>
        """
    }

    private var appProperties: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>Norviq</Application></Properties>
        """
    }

    private func coreProperties(title: String, generated: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(xml(title))</dc:title><dc:creator>Norviq</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">\(generated)</dcterms:created></cp:coreProperties>
        """
    }
}

private struct StoredZipArchive {
    let entries: [(String, Data)]

    func data() -> Data {
        var output = Data()
        var central = Data()
        for (name, payload) in entries {
            let offset = UInt32(output.count)
            let nameData = Data(name.utf8)
            let checksum = crc32(payload)
            output.appendLE(UInt32(0x0403_4B50)); output.appendLE(UInt16(20)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0))
            output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(checksum)
            output.appendLE(UInt32(payload.count)); output.appendLE(UInt32(payload.count)); output.appendLE(UInt16(nameData.count)); output.appendLE(UInt16(0))
            output.append(nameData); output.append(payload)

            central.appendLE(UInt32(0x0201_4B50)); central.appendLE(UInt16(20)); central.appendLE(UInt16(20)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(checksum)
            central.appendLE(UInt32(payload.count)); central.appendLE(UInt32(payload.count)); central.appendLE(UInt16(nameData.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0)); central.appendLE(offset); central.append(nameData)
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        output.appendLE(UInt32(0x0605_4B50)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(entries.count)); output.appendLE(UInt16(entries.count))
        output.appendLE(UInt32(central.count)); output.appendLE(centralOffset); output.appendLE(UInt16(0))
        return output
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            var value = (crc ^ UInt32(byte)) & 0xFF
            for _ in 0 ..< 8 {
                value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
            }
            crc = (crc >> 8) ^ value
        }
        return crc ^ UInt32.max
    }
}

private extension Data {
    mutating func appendLE(_ value: some FixedWidthInteger) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
