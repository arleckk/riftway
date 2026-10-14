import AppKit
import RiftwayCore
import SwiftUI

/// Riftway's colors, from its icon: deep indigo, the rift's violet, pink and
/// cyan. Every color has a light and a dark value and follows macOS's
/// appearance; the light ones are darker so they read on white (WCAG AA).
enum Theme {
    /// The app's tint: selection, links, secondary buttons.
    static let violet = Color(light: 0x6d4aff, dark: 0x9a6cff)
    /// The one prominent action of a view: Play.
    static let pink = Color(light: 0xd02d93, dark: 0xff5fd2)
    static let onPink = Color(light: 0xffffff, dark: 0x2a0820)
    /// A game that is open.
    static let cyan = Color(light: 0x0a8f9e, dark: 0x7cf3ff)
    /// The content area behind the library.
    static let canvas = Color(light: 0xf6f5ff, dark: 0x0b0b22)
    /// Cards on the canvas: notices, the controller in the sidebar.
    static let card = Color(light: 0xefecff, dark: 0x1a1640)

    static let verified = Color(light: 0x3b6d11, dark: 0xc0dd97)
    static let playable = Color(light: 0x854f0b, dark: 0xfac775)
    static let blocked = Color(light: 0xa32d2d, dark: 0xf09595)

    static func color(_ status: CompatibilityStatus) -> Color {
        switch status {
        case .verified: verified
        case .playable: playable
        case .untested: .secondary
        case .blocked: blocked
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(rgb: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }

    init(_ rgb: CoverPalette.RGB) {
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}

/// Play: pink, the only prominent button of a view.
struct PlayButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font((large ? Font.title3 : .callout).weight(.semibold))
            .padding(.horizontal, large ? 22 : 14).padding(.vertical, large ? 10 : 6)
            .foregroundStyle(Theme.onPink)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.pink))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

extension NSImage {
    /// The icon's cover colors, from a 32×32 rendering.
    var coverPalette: CoverPalette? {
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                          bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }
        // Undo the premultiplication: the palette reads straight colors.
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 0 && pixels[i + 3] < 255 {
            let alpha = Double(pixels[i + 3]) / 255
            for c in 0..<3 { pixels[i + c] = UInt8(min(255, Double(pixels[i + c]) / alpha)) }
        }
        return CoverPalette.from(rgba: pixels, width: size, height: size)
    }
}
