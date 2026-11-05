import Foundation

/// How a picked color is copied.
enum ColorFormat: String, CaseIterable, Identifiable {
    case hexUpper, hexLower, rgb, hsl, swiftUI

    var id: String { rawValue }

    /// Menu titles are examples of the result, so they need no translation, except SwiftUI's.
    var title: String {
        switch self {
        case .swiftUI: return String(localized: "SwiftUI Color")
        default: return string(red: 26 / 255, green: 43 / 255, blue: 60 / 255)
        }
    }

    /// sRGB components 0…1.
    func string(red r: Double, green g: Double, blue b: Double) -> String {
        let (R, G, B) = (Self.byte(r), Self.byte(g), Self.byte(b))
        switch self {
        case .hexUpper: return String(format: "#%02X%02X%02X", R, G, B)
        case .hexLower: return String(format: "%02x%02x%02x", R, G, B)
        case .rgb: return "rgb(\(R), \(G), \(B))"
        case .hsl:
            let (h, s, l) = Self.hsl(red: Double(R) / 255, green: Double(G) / 255, blue: Double(B) / 255)
            return "hsl(\(Int(h.rounded())) \(Int((s * 100).rounded()))% \(Int((l * 100).rounded()))%)"
        case .swiftUI:
            func f(_ v: Double) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), v) }
            return "Color(red: \(f(r)), green: \(f(g)), blue: \(f(b)))"
        }
    }

    /// Short form for the notice in the notch: the long SwiftUI form is shown as hex.
    func notice(red r: Double, green g: Double, blue b: Double) -> String {
        self == .swiftUI ? ColorFormat.hexUpper.string(red: r, green: g, blue: b) : string(red: r, green: g, blue: b)
    }

    private static func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }

    /// Hue in degrees, saturation and lightness 0…1.
    static func hsl(red r: Double, green g: Double, blue b: Double) -> (Double, Double, Double) {
        let maxV = max(r, g, b), minV = min(r, g, b)
        let l = (maxV + minV) / 2
        let d = maxV - minV
        guard d > 0 else { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        switch maxV {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h *= 60
        return (h.truncatingRemainder(dividingBy: 360), s, l)
    }
}
