import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    init?(hexString: String) {
        var value: UInt64 = 0
        guard Scanner(string: hexString).scanHexInt64(&value), value <= 0xFFFFFF else { return nil }
        self.init(hex: UInt32(value))
    }
}

/// "Neon Noir" for the SwiftUI pages (Wikipedia, home, assistant). The
/// semantic colors and interface font follow Write's preferences; the
/// reading typeface and size are the reader's own.
enum WikiTheme {
    static var defaults: UserDefaults { AppState.defaults }

    static let background = Color(hex: 0x141414)
    static let backgroundOpacity = 0.60

    static let foreground = Color(hex: 0x63D0FF)
    static let dim = Color(hex: 0x526078)
    /// Translucent secondary chrome, as in Write.
    static let secondary = Color.white.opacity(0.5)
    static let hairline = Color.white.opacity(0.08)
    static let selection = Color(hex: 0x334A7D)
    static let code = Color(hex: 0x55E6A5)

    private static func semantic(_ key: String, _ fallback: UInt32) -> Color {
        guard let stored = defaults.string(forKey: key) else { return Color(hex: fallback) }
        if stored == "none" { return foreground }
        return Color(hexString: stored) ?? Color(hex: fallback)
    }

    static let heading = semantic("headingColor", 0xA4BEEF)
    static let bold = semantic("boldColor", 0xFFFFFF)
    static let italic = semantic("italicColor", 0xD7E0FF)
    static let link = semantic("linkColor", 0x7DD3FC)
    static let quote = semantic("quoteColor", 0xBF8EE8)
    static let listMarker = semantic("listMarkerColor", 0xFFD166)
    static let inlineCode = semantic("inlineCodeColor", 0xFFB86C)

    static let lineSpacing: CGFloat = 4
    static let maxTextWidth: CGFloat = 720
    static let padding: CGFloat = 28

    // MARK: Fonts

    static let fontSizeKey = "wikiFontSize"
    static let bodyFontKey = "wikiBodyFont"
    static let fontSizeRange: ClosedRange<Double> = 14...30

    /// Starts from Write's text size until changed here.
    static var defaultFontSize: Double {
        min(max(Double(Theme.fontSize), fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    static let bodyFamilies = ["Baskerville", "Georgia", "Palatino", "Charter", "Iowan Old Style", "Verdana"]

    static var defaultBodyFamily: String {
        bodyFamilies.contains(Theme.fontFamily) ? Theme.fontFamily : "Baskerville"
    }

    static var interfaceFamily: String {
        let family = Theme.interfaceFontFamily
        return familyExists(family) ? family : "Verdana"
    }

    static func familyExists(_ family: String) -> Bool {
        NSFontManager.shared.availableFontFamilies.contains(family)
    }

    static func body(_ family: String, size: Double) -> Font {
        .custom(familyExists(family) ? family : "Baskerville", fixedSize: size)
    }

    static func interface(size: Double, weight: Font.Weight = .regular) -> Font {
        .custom(interfaceFamily, fixedSize: size).weight(weight)
    }

    static func adjustFontSize(by delta: Double) {
        let current = defaults.object(forKey: fontSizeKey) as? Double ?? defaultFontSize
        defaults.set(min(max(current + delta, fontSizeRange.lowerBound), fontSizeRange.upperBound), forKey: fontSizeKey)
    }
}

/// Reads the reader's chosen body font and size from preferences.
struct ReaderFont {
    var family: String
    var size: Double

    var body: Font { WikiTheme.body(family, size: size) }
    func scaled(_ factor: Double) -> Font { WikiTheme.body(family, size: (size * factor).rounded()) }
}
