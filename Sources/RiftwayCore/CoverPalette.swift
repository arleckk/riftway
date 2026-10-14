import Foundation

/// The two colors of a game's generated cover, from its icon (PRD-04): the
/// icon's most common saturated hue, light at the top and deep at the bottom.
/// Games whose icon has no color of its own get Riftway's violet.
public struct CoverPalette: Equatable, Sendable {
    public struct RGB: Equatable, Sendable {
        public var r, g, b: Double

        public init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        init(hue h: Double, saturation s: Double, value v: Double) {
            let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
            let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
            switch i {
            case 0: self.init(r: v, g: t, b: p)
            case 1: self.init(r: q, g: v, b: p)
            case 2: self.init(r: p, g: v, b: t)
            case 3: self.init(r: p, g: q, b: v)
            case 4: self.init(r: t, g: p, b: v)
            default: self.init(r: v, g: p, b: q)
            }
        }

        /// Hue (0..<1), saturation and value.
        var hsv: (h: Double, s: Double, v: Double) {
            let high = max(r, g, b), low = min(r, g, b), range = high - low
            guard range > 0 else { return (0, 0, high) }
            var h: Double
            if high == r { h = (g - b) / range } else if high == g { h = 2 + (b - r) / range } else { h = 4 + (r - g) / range }
            h /= 6
            if h < 0 { h += 1 }
            return (h, range / high, high)
        }
    }

    public var top: RGB
    public var bottom: RGB

    public init(top: RGB, bottom: RGB) {
        self.top = top
        self.bottom = bottom
    }

    /// Riftway's own: the icon's violet over its deep indigo.
    public static let riftway = CoverPalette(top: RGB(r: 0x6d / 255.0, g: 0x4a / 255.0, b: 1),
                                             bottom: RGB(r: 0x0b / 255.0, g: 0x0b / 255.0, b: 0x22 / 255.0))

    /// From 8-bit RGBA pixels (not premultiplied), such as a 32×32 rendering
    /// of the icon. Nil when the icon is gray, black or nearly transparent.
    public static func from(rgba pixels: [UInt8], width: Int, height: Int) -> CoverPalette? {
        let count = width * height
        guard count > 0, pixels.count >= count * 4 else { return nil }
        // Twelve hue buckets; the hue covering most of the icon wins, each
        // pixel weighing by how colorful it is (so a bright detail does not
        // outweigh the icon's own background or frame).
        var weight = [Double](repeating: 0, count: 12)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: 12)
        for i in 0..<count {
            let alpha = Double(pixels[i * 4 + 3]) / 255
            guard alpha > 0.5 else { continue }
            let color = RGB(r: Double(pixels[i * 4]) / 255, g: Double(pixels[i * 4 + 1]) / 255, b: Double(pixels[i * 4 + 2]) / 255)
            let (h, s, v) = color.hsv
            guard s > 0.25, v > 0.2 else { continue }
            let bucket = min(11, Int(h * 12)), w = s
            weight[bucket] += w
            sums[bucket].r += color.r * w
            sums[bucket].g += color.g * w
            sums[bucket].b += color.b * w
        }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > Double(count) * 0.02 else { return nil }
        let mean = RGB(r: sums[best].r / weight[best], g: sums[best].g / weight[best], b: sums[best].b / weight[best])
        let (h, s, _) = mean.hsv
        let saturation = min(max(s, 0.45), 0.85)
        // The bottom leans a little toward violet, Riftway's own hue.
        let deep = (h + (h < 0.75 && h > 0.25 ? 0.03 : -0.03) + 1).truncatingRemainder(dividingBy: 1)
        return CoverPalette(top: RGB(hue: h, saturation: saturation, value: 0.72),
                            bottom: RGB(hue: deep, saturation: min(1, saturation + 0.1), value: 0.2))
    }
}
