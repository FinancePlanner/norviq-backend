import Foundation
import NIOCore

/// A `multipart/form-data` body that can carry binary parts.
///
/// Written by hand for the same reason `TelegramClient` is: two call sites and
/// a fixed shape do not justify a dependency. The part that matters is
/// `addFile` — audio is not UTF-8, so parts are written as bytes, never as a
/// string.
struct MultipartBody {
    let boundary: String
    private var buffer: ByteBuffer

    init(boundary: String = "norviq-\(UUID().uuidString)", reservingCapacity capacity: Int = 512) {
        self.boundary = boundary
        buffer = ByteBufferAllocator().buffer(capacity: capacity)
    }

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    mutating func addField(name: String, value: String) {
        buffer.writeString("--\(boundary)\r\n")
        buffer.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        buffer.writeString(value)
        buffer.writeString("\r\n")
    }

    mutating func addFile(name: String, filename: String, contentType: String, bytes: [UInt8]) {
        buffer.writeString("--\(boundary)\r\n")
        buffer.writeString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        buffer.writeString("Content-Type: \(contentType)\r\n\r\n")
        buffer.writeBytes(bytes)
        buffer.writeString("\r\n")
    }

    mutating func addFile(name: String, filename: String, contentType: String, buffer audio: ByteBuffer) {
        var audio = audio
        addFile(
            name: name,
            filename: filename,
            contentType: contentType,
            bytes: audio.readBytes(length: audio.readableBytes) ?? []
        )
    }

    /// The body with its closing boundary. Non-mutating so callers can keep
    /// adding parts up to the moment they send.
    func finalized() -> ByteBuffer {
        var out = buffer
        out.writeString("--\(boundary)--\r\n")
        return out
    }
}
