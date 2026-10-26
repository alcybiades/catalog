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
}

/// The current palette for the SwiftUI pages (Wikipedia, home, assistant).
/// Views reading these colors re-render when the theme changes. The
/// semantic colors and interface font follow Catalog's preferences; the
/// reading typeface and size are the reader's own.
enum WikiTheme {
    static var defaults: UserDefaults { AppState.defaults }

    private static var palette: Palette { ThemeStore.shared.palette }

    static var colorScheme: ColorScheme { palette.isDark ? .dark : .light }
    static var background: Color { Color(nsColor: palette.background) }
    static var foreground: Color { Color(nsColor: palette.foreground) }
    static var dim: Color { Color(nsColor: palette.dim) }
    /// Translucent secondary chrome, as in Catalog's editor.
    static var secondary: Color { Color(nsColor: palette.secondary) }
    /// Fills drawn at low opacity: white on dark themes, ink on light ones.
    static var wash: Color { Color(nsColor: palette.wash) }
    static var hairline: Color { wash.opacity(0.08) }
    static var sidebarFill: Color { Color(nsColor: palette.sidebarFill) }
    static var selection: Color { Color(nsColor: palette.selection) }
    static var code: Color { Color(nsColor: palette.code) }
    static var codeBlockBackground: Color { Color(nsColor: palette.codeBlockBackground) }
    static var bubble: Color { Color(nsColor: palette.bubble) }
    static var bubbleText: Color { Color(nsColor: palette.bubbleText) }
    static var send: Color { Color(nsColor: palette.send) }
    static var sendGlyph: Color { Color(nsColor: palette.sendGlyph) }
    static var danger: Color { Color(nsColor: palette.danger) }
    static var diagramBase: Color { Color(nsColor: palette.diagramBase) }

    /// "No color" draws in the foreground.
    private static func semantic(_ color: NSColor?) -> Color {
        color.map { Color(nsColor: $0) } ?? foreground
    }

    static var heading: Color { semantic(palette.heading) }
    static var bold: Color { semantic(palette.bold) }
    static var italic: Color { semantic(palette.italic) }
    static var link: Color { semantic(palette.link) }
    static var quote: Color { semantic(palette.quote) }
    static var listMarker: Color { semantic(palette.listMarker) }
    static var inlineCode: Color { semantic(palette.inlineCode) }

    /// Colors article and chat text by its inline intents, when it's drawn
    /// rather than when it's parsed, so cached articles follow the theme.
    static func styled(_ text: AttributedString) -> AttributedString {
        var text = text
        let bold = bold, italic = italic, inlineCode = inlineCode
        let underline = Text.LineStyle(pattern: .solid, color: link.opacity(0.25))
        for run in text.runs {
            if run.link != nil { text[run.range].underlineStyle = underline }
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.code) { text[run.range].foregroundColor = inlineCode }
            else if intent.contains(.stronglyEmphasized) { text[run.range].foregroundColor = bold }
            else if intent.contains(.emphasized) { text[run.range].foregroundColor = italic }
        }
        return text
    }

    static let lineSpacing: CGFloat = 4
    static let maxTextWidth: CGFloat = 720
    static let padding: CGFloat = 28

    // MARK: Fonts

    static let fontSizeKey = "wikiFontSize"
    static let bodyFontKey = "wikiBodyFont"
    static let fontSizeRange: ClosedRange<Double> = 14...30

    /// Starts from the editor's text size until changed here.
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
