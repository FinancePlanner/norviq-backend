import Foundation
@testable import StockPlanBackend
import Testing
import Vapor

@Suite("Article image sniffing")
struct ArticleImageSnifferTests {
    /// Minimal PNG: signature + IHDR with the given size. Pixels are not needed.
    static func png(width: UInt32, height: UInt32) -> [UInt8] {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
        bytes += withUnsafeBytes(of: width.bigEndian, Array.init)
        bytes += withUnsafeBytes(of: height.bigEndian, Array.init)
        bytes += [8, 6, 0, 0, 0, 0, 0, 0, 0]
        return bytes
    }

    /// Minimal JPEG: SOI, an APP0 segment, then SOF0 with the given size.
    static func jpeg(width: UInt16, height: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xC0, 0x00, 0x11, 0x08]
        bytes += withUnsafeBytes(of: height.bigEndian, Array.init)
        bytes += withUnsafeBytes(of: width.bigEndian, Array.init)
        bytes += [0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]
        return bytes
    }

    /// Minimal lossy WebP (VP8): RIFF header, VP8 chunk with a keyframe header.
    static func webp(width: UInt16, height: UInt16) -> [UInt8] {
        var bytes: [UInt8] = Array("RIFF".utf8) + [0x24, 0, 0, 0] + Array("WEBPVP8 ".utf8) + [0x18, 0, 0, 0]
        bytes += [0x30, 0x01, 0x00, 0x9D, 0x01, 0x2A]
        bytes += withUnsafeBytes(of: width.littleEndian, Array.init)
        bytes += withUnsafeBytes(of: height.littleEndian, Array.init)
        bytes += [UInt8](repeating: 0, count: 8)
        return bytes
    }

    @Test("PNG, JPEG and WebP report type and size")
    func knownTypes() throws {
        let png = try ArticleImageSniffer.sniff(Self.png(width: 1200, height: 630))
        #expect(png.contentType == "image/png" && png.width == 1200 && png.height == 630)
        let jpeg = try ArticleImageSniffer.sniff(Self.jpeg(width: 800, height: 600))
        #expect(jpeg.contentType == "image/jpeg" && jpeg.width == 800 && jpeg.height == 600)
        let webp = try ArticleImageSniffer.sniff(Self.webp(width: 640, height: 480))
        #expect(webp.contentType == "image/webp" && webp.width == 640 && webp.height == 480)
    }

    @Test("JPEG fill bytes (repeated 0xFF) before a marker are skipped")
    func jpegFillBytes() throws {
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xFF, 0xFF, 0xC0, 0x00, 0x11, 0x08]
        bytes += withUnsafeBytes(of: UInt16(480).bigEndian, Array.init)
        bytes += withUnsafeBytes(of: UInt16(640).bigEndian, Array.init)
        bytes += [0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]
        let jpeg = try ArticleImageSniffer.sniff(bytes)
        #expect(jpeg.contentType == "image/jpeg" && jpeg.width == 640 && jpeg.height == 480)
    }

    @Test("an SVG or HTML file is unsupported media")
    func unknownType() {
        #expect {
            try ArticleImageSniffer.sniff(Array("<svg onload=alert(1)>".utf8))
        } throws: { ($0 as? any AbortError)?.status == .unsupportedMediaType }
    }

    @Test("over 2 MB is too large; over 4096 px a side is rejected")
    func limits() {
        let big = Self.png(width: 10, height: 10) + [UInt8](repeating: 0, count: 2_000_001)
        #expect { try ArticleImageSniffer.sniff(big) } throws: { ($0 as? any AbortError)?.status == .payloadTooLarge }
        #expect { try ArticleImageSniffer.sniff(Self.png(width: 5000, height: 10)) } throws: { ($0 as? any AbortError)?.status == .badRequest }
    }
}
