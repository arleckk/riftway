// Renders an SVG to square PNGs: swift scripts/render-icon.swift icon.svg out-dir 16 32 …
import AppKit

let args = CommandLine.arguments
guard args.count > 3, let image = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: render-icon.swift icon.svg out-dir size…\n".utf8))
    exit(1)
}
for size in args.dropFirst(3).compactMap({ Int($0) }) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(args[2])/\(size).png"))
}
