import Foundation
import Vapor

struct SniffedImage: Equatable {
    let contentType: String
    let width: Int
    let height: Int
}

/// Identifies a cover image by its bytes, never by the client's claimed type,
/// so an SVG or HTML file can't be stored and served back as an "image".
enum ArticleImageSniffer {
    static let maxBytes = 2_000_000
    static let maxSide = 4096

    static func sniff(_ bytes: [UInt8]) throws -> SniffedImage {
        guard bytes.count <= maxBytes else {
            throw Abort(.payloadTooLarge, reason: "Images must be 2 MB or smaller.")
        }
        let image: SniffedImage?
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            image = png(bytes)
        } else if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            image = jpeg(bytes)
        } else if bytes.count >= 12, bytes[0 ..< 4] == [0x52, 0x49, 0x46, 0x46], bytes[8 ..< 12] == [0x57, 0x45, 0x42, 0x50] {
            image = webp(bytes)
        } else {
            throw Abort(.unsupportedMediaType, reason: "Use a JPEG, PNG or WebP image.")
        }
        guard let image, image.width > 0, image.height > 0 else {
            throw Abort(.badRequest, reason: "That image file looks damaged.")
        }
        guard image.width <= maxSide, image.height <= maxSide else {
            throw Abort(.badRequest, reason: "Images can be at most 4096 pixels on a side.")
        }
        return image
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) << 8 | Int(b[i + 1])
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | Int(b[i + 1]) << 8
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }

    private static func png(_ b: [UInt8]) -> SniffedImage? {
        guard b.count >= 24 else { return nil }
        return SniffedImage(contentType: "image/png", width: be32(b, 16), height: be32(b, 20))
    }

    /// Walks the marker segments to the first start-of-frame.
    private static func jpeg(_ b: [UInt8]) -> SniffedImage? {
        var i = 2
        while i + 9 < b.count {
            guard b[i] == 0xFF else { return nil }
            // Any marker may be preceded by 0xFF fill bytes.
            if b[i + 1] == 0xFF {
                i += 1
                continue
            }
            let marker = b[i + 1]
            let length = be16(b, i + 2)
            let isStartOfFrame = (0xC0 ... 0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker)
            if isStartOfFrame {
                return SniffedImage(contentType: "image/jpeg", width: be16(b, i + 7), height: be16(b, i + 5))
            }
            guard length >= 2 else { return nil }
            i += 2 + length
        }
        return nil
    }

    private static func webp(_ b: [UInt8]) -> SniffedImage? {
        guard b.count >= 30 else { return nil }
        let chunk = Array(b[12 ..< 16])
        switch chunk {
        case Array("VP8 ".utf8):
            return SniffedImage(contentType: "image/webp", width: le16(b, 26) & 0x3FFF, height: le16(b, 28) & 0x3FFF)
        case Array("VP8L".utf8):
            let bits = Int(b[21]) | Int(b[22]) << 8 | Int(b[23]) << 16 | Int(b[24]) << 24
            return SniffedImage(contentType: "image/webp", width: (bits & 0x3FFF) + 1, height: ((bits >> 14) & 0x3FFF) + 1)
        case Array("VP8X".utf8):
            let width = (Int(b[24]) | Int(b[25]) << 8 | Int(b[26]) << 16) + 1
            let height = (Int(b[27]) | Int(b[28]) << 8 | Int(b[29]) << 16) + 1
            return SniffedImage(contentType: "image/webp", width: width, height: height)
        default:
            return nil
        }
    }
}
