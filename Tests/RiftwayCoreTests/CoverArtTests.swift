import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RiftwayCore

@Suite struct CoverArtTests {
    /// A width×height JPEG of one color.
    private func jpeg(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func size(_ data: Data) throws -> (Int, Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    private func bottle() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("riftway-cover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func keepsAScaledPNGCopyInTheBottle() throws {
        let root = try bottle()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CoverArt.data(in: root) == nil)
        try CoverArt.set(try jpeg(width: 1600, height: 2400), in: root)
        let saved = try #require(CoverArt.data(in: root))
        #expect(saved.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let (width, height) = try size(saved)
        #expect(height == CoverArt.maxPixelSize && width == 800)
        try CoverArt.remove(in: root)
        #expect(CoverArt.data(in: root) == nil)
        try CoverArt.remove(in: root)
    }

    @Test func neverEnlargesASmallImage() throws {
        let root = try bottle()
        defer { try? FileManager.default.removeItem(at: root) }
        try CoverArt.set(try jpeg(width: 200, height: 300), in: root)
        let (width, height) = try size(try #require(CoverArt.data(in: root)))
        #expect(width == 200 && height == 300)
    }

    @Test func refusesWhatIsNotAnImage() throws {
        let root = try bottle()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: CoverArt.Unreadable.self) { try CoverArt.set(Data("MZ not an image".utf8), in: root) }
        #expect(CoverArt.data(in: root) == nil)
    }
}
