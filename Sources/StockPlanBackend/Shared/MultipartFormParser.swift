import Foundation
import MultipartKit
import NIOCore
import NIOHTTP1
import Vapor

/// One parsed `multipart/form-data` body.
///
/// `FormDataDecoder` only builds an array when the part name is `file[]`.
/// Clients repeat a plain `file` part for each image, and decoding that as
/// `[File]` throws. This parser keeps every part with that name.
struct ParsedMultipartForm: Sendable {
    struct File: Sendable {
        var fieldName: String
        var filename: String
        var contentType: String
        var body: ByteBuffer
    }

    var fields: [String: String]
    var files: [File]
}

enum MultipartFormParser {
    /// Field names that carry an uploaded image. `file[]` and `file[0]` collapse
    /// to `file` so either spelling is accepted.
    static let imageFieldNames: Set<String> = ["file", "image", "files"]

    static func parse(buffer: ByteBuffer, boundary: String) throws -> ParsedMultipartForm {
        let trimmed = boundary.trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespacesAndNewlines))
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "Upload the form as multipart/form-data.")
        }

        let accumulator = Accumulator()
        let parser = MultipartParser(boundary: trimmed)
        parser.onHeader = { name, value in
            accumulator.headers.replaceOrAdd(name: name, value: value)
        }
        parser.onBody = { chunk in
            accumulator.body.writeBytes(chunk.readableBytesView)
        }
        parser.onPartComplete = {
            accumulator.finishPart()
        }
        do {
            try parser.execute(buffer)
        } catch {
            throw Abort(.badRequest, reason: "Could not read the uploaded form.")
        }
        return ParsedMultipartForm(fields: accumulator.fields, files: accumulator.files)
    }

    static func canonicalFieldName(_ raw: String) -> String {
        guard let bracket = raw.firstIndex(of: "[") else { return raw }
        return String(raw[..<bracket])
    }
}

private final class Accumulator: @unchecked Sendable {
    var headers = HTTPHeaders()
    var body = ByteBuffer()
    var fields: [String: String] = [:]
    var files: [ParsedMultipartForm.File] = []

    func finishPart() {
        let disposition = Self.parameters(headers.first(name: "Content-Disposition"))
        let name = MultipartFormParser.canonicalFieldName(disposition["name"] ?? "")
        if MultipartFormParser.imageFieldNames.contains(name), let filename = disposition["filename"] {
            let type = headers.first(name: "Content-Type") ?? "application/octet-stream"
            files.append(.init(fieldName: name, filename: filename, contentType: type, body: body))
        } else if fields[name] == nil, let text = body.getString(at: body.readerIndex, length: body.readableBytes) {
            fields[name] = text
        }
        headers = HTTPHeaders()
        body = ByteBuffer()
    }

    /// `name="file"; filename="shot.jpg"` → those two keys. Quotes around a value are stripped.
    static func parameters(_ header: String?) -> [String: String] {
        guard let header else { return [:] }
        var result: [String: String] = [:]
        for piece in header.split(separator: ";").dropFirst() {
            let halves = piece.split(separator: "=", maxSplits: 1)
            guard halves.count == 2 else { continue }
            let key = halves[0].trimmingCharacters(in: .whitespaces)
            var value = halves[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }
}
