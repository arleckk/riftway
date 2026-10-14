import Testing
@testable import RiftwayCore

@Suite struct CoverPaletteTests {
    /// A width×height image filled by `color(x, y)` as RGBA.
    private func image(_ size: Int, _ color: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        var pixels: [UInt8] = []
        for y in 0..<size {
            for x in 0..<size {
                let (r, g, b, a) = color(x, y)
                pixels += [r, g, b, a]
            }
        }
        return pixels
    }

    @Test func takesTheIconsMainColor() throws {
        // Mostly blue, with a red corner and a white background ring.
        let pixels = image(16) { x, y in
            if x < 2 || y < 2 { return (255, 255, 255, 255) }
            if x > 12 && y > 12 { return (230, 20, 20, 255) }
            return (30, 90, 220, 255)
        }
        let palette = try #require(CoverPalette.from(rgba: pixels, width: 16, height: 16))
        #expect(palette.top.b > palette.top.r && palette.top.b > palette.top.g)
        // Light at the top, deep at the bottom.
        #expect(palette.top.hsv.v > palette.bottom.hsv.v + 0.4)
    }

    @Test func grayOrTransparentIconsHaveNone() {
        let gray = image(8) { _, _ in (120, 120, 120, 255) }
        #expect(CoverPalette.from(rgba: gray, width: 8, height: 8) == nil)
        let clear = image(8) { _, _ in (255, 0, 0, 0) }
        #expect(CoverPalette.from(rgba: clear, width: 8, height: 8) == nil)
        #expect(CoverPalette.from(rgba: [], width: 0, height: 0) == nil)
    }

    @Test func dullColorsAreLifted() throws {
        let olive = image(8) { _, _ in (110, 120, 70, 255) }
        let palette = try #require(CoverPalette.from(rgba: olive, width: 8, height: 8))
        #expect(palette.top.hsv.s >= 0.45 - 1e-9)
        #expect(abs(palette.top.hsv.v - 0.72) < 1e-6)
    }
}
