import NIOCore
@testable import StockPlanBackend
import Testing

@Suite("Multipart form parser")
struct MultipartFormParserTests {
    @Test("A single file part named file is an image, not a decode error")
    func singleFilePart() throws {
        var body = MultipartBody(boundary: "B")
        body.addField(name: "provider", value: "manual")
        body.addFile(name: "file", filename: "shot.jpg", contentType: "image/jpeg", bytes: [0xFF, 0xD8, 0xFF])

        let form = try MultipartFormParser.parse(buffer: body.finalized(), boundary: "B")

        #expect(form.fields["provider"] == "manual")
        #expect(form.files.count == 1)
        #expect(form.files[0].fieldName == "file")
        #expect(form.files[0].filename == "shot.jpg")
        #expect(form.files[0].contentType == "image/jpeg")
        #expect(form.files[0].body.readableBytes == 3)
    }

    @Test("Repeated file parts are all kept, in order")
    func repeatedFileParts() throws {
        var body = MultipartBody(boundary: "B")
        body.addFile(name: "file", filename: "a.jpg", contentType: "image/jpeg", bytes: [0x01])
        body.addFile(name: "file", filename: "b.jpg", contentType: "image/png", bytes: [0x02, 0x03])

        let form = try MultipartFormParser.parse(buffer: body.finalized(), boundary: "B")

        #expect(form.files.map(\.filename) == ["a.jpg", "b.jpg"])
        #expect(form.files.map(\.body.readableBytes) == [1, 2])
        #expect(form.files.map(\.contentType) == ["image/jpeg", "image/png"])
    }

    @Test("A file[] part is the same field as file")
    func bracketedFileName() throws {
        var body = MultipartBody(boundary: "B")
        body.addFile(name: "file[]", filename: "shot.jpg", contentType: "image/jpeg", bytes: [0xFF])

        let form = try MultipartFormParser.parse(buffer: body.finalized(), boundary: "B")

        #expect(form.files.map(\.fieldName) == ["file"])
    }
}
