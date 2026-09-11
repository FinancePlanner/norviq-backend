import Foundation
import NIOCore
@testable import StockPlanBackend
import Testing

/// The only multipart writer in the codebase before this wrote strings only,
/// which is fine for HTML and wrong for audio: any byte sequence that is not
/// valid UTF-8 would be mangled on the way out.
@Suite("Multipart body")
struct MultipartBodyTests {
    private func render(_ body: MultipartBody) -> String {
        var buffer = body.finalized()
        return buffer.readString(length: buffer.readableBytes) ?? ""
    }

    @Test("A text field is framed with its boundary")
    func writesTextField() {
        var body = MultipartBody(boundary: "B")
        body.addField(name: "model", value: "whisper-large-v3-turbo")
        let out = render(body)
        #expect(out.contains("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n"))
        #expect(out.hasSuffix("--B--\r\n"))
    }

    @Test("The content type header carries the boundary")
    func exposesContentType() {
        #expect(MultipartBody(boundary: "B").contentType == "multipart/form-data; boundary=B")
    }

    @Test("Arbitrary bytes survive the round trip unchanged")
    func preservesBinaryBytes() {
        // 0xFF 0xFE is not valid UTF-8. A string-only writer loses this.
        let audio: [UInt8] = [0xFF, 0xFE, 0x00, 0x4F, 0x67, 0x67, 0x53]
        var body = MultipartBody(boundary: "B")
        body.addFile(name: "file", filename: "voice.ogg", contentType: "audio/ogg", bytes: audio)

        var buffer = body.finalized()
        let raw = buffer.readBytes(length: buffer.readableBytes) ?? []
        let needle = Array("\r\n\r\n".utf8)
        guard let headerEnd = raw.firstRange(of: needle) else {
            Issue.record("no header terminator"); return
        }
        let payload = Array(raw[headerEnd.upperBound...].prefix(audio.count))
        #expect(payload == audio)
    }

    @Test("A file part declares its filename and content type")
    func writesFileHeaders() {
        var body = MultipartBody(boundary: "B")
        body.addFile(name: "file", filename: "voice.ogg", contentType: "audio/ogg", bytes: [0x01])
        let out = render(body)
        #expect(out.contains("Content-Disposition: form-data; name=\"file\"; filename=\"voice.ogg\""))
        #expect(out.contains("Content-Type: audio/ogg"))
    }

    @Test("Several parts keep their order")
    func keepsPartOrder() throws {
        var body = MultipartBody(boundary: "B")
        body.addFile(name: "file", filename: "a.ogg", contentType: "audio/ogg", bytes: [0x01])
        body.addField(name: "model", value: "m")
        body.addField(name: "prompt", value: "NVDA AAPL")
        let out = render(body)
        let fileAt = try #require(out.range(of: "a.ogg")?.lowerBound)
        let modelAt = try #require(out.range(of: "name=\"model\"")?.lowerBound)
        let promptAt = try #require(out.range(of: "name=\"prompt\"")?.lowerBound)
        #expect(fileAt < modelAt)
        #expect(modelAt < promptAt)
    }

    @Test("An empty body is still a well-formed closing boundary")
    func emptyBodyCloses() {
        #expect(render(MultipartBody(boundary: "B")) == "--B--\r\n")
    }
}

/// Characterisation: the Gotenberg body was hand-built before it moved onto
/// `MultipartBody`. These bytes are what Gotenberg already accepted in
/// production, so they are the contract the refactor had to preserve.
@Suite("Gotenberg multipart body")
struct GotenbergBodyTests {
    @Test("The refactored body is byte-identical to the hand-built one")
    func matchesLegacyBytes() {
        let html = "<html><body>hi &amp; bye</body></html>"
        let boundary = "B"

        var expected = ByteBufferAllocator().buffer(capacity: 512)
        expected.writeString("--\(boundary)\r\n")
        expected.writeString("Content-Disposition: form-data; name=\"files\"; filename=\"index.html\"\r\n")
        expected.writeString("Content-Type: text/html; charset=utf-8\r\n\r\n")
        expected.writeString(html)
        expected.writeString("\r\n--\(boundary)\r\n")
        expected.writeString("Content-Disposition: form-data; name=\"printBackground\"\r\n\r\ntrue\r\n")
        expected.writeString("--\(boundary)--\r\n")

        var actual = AdvancedReportGenerator.gotenbergBody(html: html, boundary: boundary).finalized()
        #expect(actual.readBytes(length: actual.readableBytes) == expected.readBytes(length: expected.readableBytes))
    }
}
