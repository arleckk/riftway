import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A game's own cover (PRD-04): an image the player chose, in place of the
/// one Riftway draws from the game's icon. Riftway keeps its own copy in the
/// bottle (`<bottle>/cover.png`), so it leaves with the game and the player's
/// file stays where it was.
public enum CoverArt {
    public static let fileName = "cover.png"
    /// The copy's longest side, in pixels: twice the largest a cover shows.
    public static let maxPixelSize = 1200

    public struct Unreadable: Error, CustomStringConvertible {
        public var description: String { "No es una imagen que Riftway pueda leer." }
    }

    public static func url(in bottle: URL) -> URL {
        bottle.appendingPathComponent(fileName)
    }

    /// The cover's PNG, or nil when the game has none of its own.
    public static func data(in bottle: URL) -> Data? {
        try? Data(contentsOf: url(in: bottle))
    }

    /// Makes `image` (any format ImageIO reads: PNG, JPEG, HEIC, WebP…) the
    /// game's cover: upright, no larger than `maxPixelSize`, as PNG.
    public static func set(_ image: Data, in bottle: URL) throws {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw Unreadable()
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Unreadable() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw Unreadable()
        }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { throw Unreadable() }
        try (output as Data).write(to: url(in: bottle), options: .atomic)
    }

    /// Back to the cover drawn from the icon. Removes only Riftway's copy.
    public static func remove(in bottle: URL) throws {
        let file = url(in: bottle)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
