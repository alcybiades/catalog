import AppKit
import Observation

extension NSColor {
    convenience init?(hexString: String) {
        var value: UInt64 = 0
        guard Scanner(string: hexString).scanHexInt64(&value), value <= 0xFFFFFF else { return nil }
        self.init(hex: UInt32(value))
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }

    var rgbHexString: String? {
        guard let color = usingColorSpace(.sRGB) else { return nil }
        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", red, green, blue)
    }
}

/// Token colors inside fenced code; untokenized code keeps `Palette.code`.
struct SyntaxColors {
    var keyword, string, comment, number, type, function: NSColor

    init(keyword: UInt32, string: UInt32, comment: UInt32, number: UInt32, type: UInt32, function: UInt32) {
        (self.keyword, self.string, self.comment) = (NSColor(hex: keyword), NSColor(hex: string), NSColor(hex: comment))
        (self.number, self.type, self.function) = (NSColor(hex: number), NSColor(hex: type), NSColor(hex: function))
    }

    subscript(token: CodeToken) -> NSColor {
        switch token {
        case .keyword: return keyword
        case .string: return string
        case .comment: return comment
        case .number: return number
        case .type: return type
        case .function: return function
        }
    }
}

/// The app's color themes. Plasma, the original, tints a background blur;
/// the others are opaque.
enum ThemeKind: String, CaseIterable {
    case plasma, dark, light, paper

    var title: String { rawValue.capitalized }

    /// The defaults key for this theme's override of a semantic color.
    /// Plasma keeps the original unprefixed keys.
    func key(_ name: String) -> String { self == .plasma ? name : "\(rawValue).\(name)" }

    static var current: ThemeKind {
        get { AppState.defaults.string(forKey: "theme").flatMap(ThemeKind.init) ?? .plasma }
        set {
            AppState.defaults.set(newValue.rawValue, forKey: "theme")
            ThemeStore.shared.reload()
        }
    }
}

/// Every color one theme draws with. The semantic colors (bold through
/// link) are the theme's defaults until `resolved` applies the user's
/// overrides from Settings; nil leaves that text in the foreground color.
struct Palette {
    var isDark: Bool
    var background: NSColor
    /// The tint's opacity over the window blur; opaque themes have no blur.
    var backgroundOpacity: CGFloat
    var blurRadius: Int
    var foreground: NSColor
    /// Subdued Markdown syntax.
    var dim: NSColor
    /// Secondary chrome: inactive tabs, status, captions.
    var secondary: NSColor
    /// Hover, selection, and field fills, always drawn at low opacity.
    var wash: NSColor
    var sidebarFill: NSColor
    var code: NSColor
    var cursor: NSColor
    var selection: NSColor
    var selectedText: NSColor
    var sidebarSelection: NSColor
    var codeBackground: NSColor
    var codeBlockBackground: NSColor
    var syntax: SyntaxColors
    /// The user's turns in the assistant transcript.
    var bubble: NSColor
    var bubbleText: NSColor
    /// The assistant's send button and the arrow on it.
    var send: NSColor
    var sendGlyph: NSColor
    var danger: NSColor
    /// Timeline bars mix their Wikipedia color into this.
    var diagramBase: NSColor

    var bold: NSColor?
    var heading: NSColor?
    var italic: NSColor?
    var inlineCode: NSColor?
    var listMarker: NSColor?
    var quote: NSColor?
    var link: NSColor?

    var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }

    static func named(_ kind: ThemeKind) -> Palette {
        switch kind {
        case .plasma: return plasma
        case .dark: return dark
        case .light: return light
        case .paper: return paper
        }
    }

    /// "Neon Noir" — mirrors ~/.wezterm.lua.
    static let plasma = Palette(
        isDark: true,
        background: NSColor(hex: 0x141414), backgroundOpacity: 0.60, blurRadius: 30,
        foreground: NSColor(hex: 0x63D0FF), dim: NSColor(hex: 0x526078),
        secondary: NSColor.white.withAlphaComponent(0.5), wash: .white,
        sidebarFill: NSColor.black.withAlphaComponent(0.10),
        code: NSColor(hex: 0x55E6A5), cursor: NSColor(hex: 0x727272),
        selection: NSColor(hex: 0x334A7D), selectedText: NSColor(hex: 0xF8FAFC),
        sidebarSelection: NSColor(hex: 0x7186A5, alpha: 0.28),
        codeBackground: NSColor(hex: 0x2E2E2E, alpha: 0.5),
        codeBlockBackground: NSColor(hex: 0x2E2E2E, alpha: 0.5),
        syntax: .init(keyword: 0xC39BFF, string: 0xFFB86C, comment: 0x6A7A96,
                      number: 0xFF8A7A, type: 0x63D0FF, function: 0xA4BEEF),
        bubble: NSColor.black.withAlphaComponent(0.25), bubbleText: NSColor.white.withAlphaComponent(0.92),
        send: .white, sendGlyph: NSColor(hex: 0x141414),
        danger: NSColor(hex: 0xFF8A7A), diagramBase: NSColor(hex: 0x1C1D22),
        bold: NSColor(hex: 0xFFFFFF), heading: NSColor(hex: 0xA4BEEF), italic: NSColor(hex: 0xD7E0FF),
        inlineCode: NSColor(hex: 0xFFB86C), listMarker: NSColor(hex: 0xFFD166),
        quote: NSColor(hex: 0xBF8EE8), link: NSColor(hex: 0x7DD3FC))

    /// Neutral graphite: soft off-white text and a restrained blue.
    static let dark = Palette(
        isDark: true,
        background: NSColor(hex: 0x212121), backgroundOpacity: 1, blurRadius: 0,
        foreground: NSColor(hex: 0xE3E3E3), dim: NSColor(hex: 0x6B6B6B),
        secondary: NSColor.white.withAlphaComponent(0.5), wash: .white,
        sidebarFill: NSColor.black.withAlphaComponent(0.28),
        code: NSColor(hex: 0xD4D4D4), cursor: NSColor(hex: 0xECECEC),
        selection: NSColor(hex: 0x3B4F6E), selectedText: NSColor(hex: 0xFFFFFF),
        sidebarSelection: NSColor.white.withAlphaComponent(0.09),
        codeBackground: NSColor.white.withAlphaComponent(0.09),
        codeBlockBackground: NSColor(hex: 0x171717),
        syntax: .init(keyword: 0x8FB3E8, string: 0xD9A77F, comment: 0x7A7A7A,
                      number: 0xC4A5DE, type: 0x86C8B8, function: 0xE3D7A3),
        bubble: NSColor.white.withAlphaComponent(0.08), bubbleText: NSColor(hex: 0xECECEC),
        send: NSColor(hex: 0x3D7FE0), sendGlyph: .white,
        danger: NSColor(hex: 0xF28B82), diagramBase: NSColor(hex: 0x262626),
        bold: NSColor(hex: 0xFFFFFF), heading: NSColor(hex: 0xF4F4F4), italic: NSColor(hex: 0xD0D0D0),
        inlineCode: NSColor(hex: 0xE6B98C), listMarker: NSColor(hex: 0x9B9B9B),
        quote: NSColor(hex: 0xB4B4B4), link: NSColor(hex: 0x7CB2F2))

    /// White surfaces, near-black text, gray secondary text.
    static let light = Palette(
        isDark: false,
        background: NSColor(hex: 0xFFFFFF), backgroundOpacity: 1, blurRadius: 0,
        foreground: NSColor(hex: 0x1F1F1F), dim: NSColor(hex: 0xA8A8A8),
        secondary: NSColor.black.withAlphaComponent(0.5), wash: .black,
        sidebarFill: NSColor.black.withAlphaComponent(0.025),
        code: NSColor(hex: 0x2B2B2B), cursor: NSColor(hex: 0x0D0D0D),
        selection: NSColor(hex: 0xC6DCF8), selectedText: NSColor(hex: 0x0D0D0D),
        sidebarSelection: NSColor.black.withAlphaComponent(0.06),
        codeBackground: NSColor.black.withAlphaComponent(0.06),
        codeBlockBackground: NSColor(hex: 0xF5F5F5),
        syntax: .init(keyword: 0xCF222E, string: 0x0A3069, comment: 0x6E7781,
                      number: 0x0550AE, type: 0x953800, function: 0x8250DF),
        bubble: NSColor.black.withAlphaComponent(0.05), bubbleText: NSColor(hex: 0x0D0D0D),
        send: NSColor(hex: 0x1F62D0), sendGlyph: .white,
        danger: NSColor(hex: 0xC5221F), diagramBase: NSColor(hex: 0xFFFFFF),
        bold: NSColor(hex: 0x000000), heading: NSColor(hex: 0x0D0D0D), italic: NSColor(hex: 0x3A3A3A),
        inlineCode: NSColor(hex: 0xB0412E), listMarker: NSColor(hex: 0x8F8F8F),
        quote: NSColor(hex: 0x5D5D5D), link: NSColor(hex: 0x1F62D0))

    /// Cream paper, near-black ink, and muted earthy accents.
    static let paper = Palette(
        isDark: false,
        background: NSColor(hex: 0xF6EFDF), backgroundOpacity: 1, blurRadius: 0,
        foreground: NSColor(hex: 0x1F1F1F), dim: NSColor(hex: 0xB3A48C),
        secondary: NSColor.black.withAlphaComponent(0.55), wash: .black,
        sidebarFill: NSColor(hex: 0x8A6A3A, alpha: 0.06),
        code: NSColor(hex: 0x5F6B2C), cursor: NSColor(hex: 0x1F1F1F),
        selection: NSColor(hex: 0xEADBB8), selectedText: NSColor(hex: 0x111111),
        sidebarSelection: NSColor(hex: 0x8A6A3A, alpha: 0.14),
        codeBackground: NSColor(hex: 0x8A6A3A, alpha: 0.10),
        codeBlockBackground: NSColor(hex: 0xEFE5D0),
        syntax: .init(keyword: 0x9A3B2E, string: 0x2F6F8F, comment: 0x9C8C70,
                      number: 0xB07D2B, type: 0x7F6A8A, function: 0x3F4A1C),
        bubble: NSColor(hex: 0x8A6A3A, alpha: 0.09), bubbleText: NSColor(hex: 0x1A1A1A),
        send: NSColor(hex: 0x1A1A1A), sendGlyph: NSColor(hex: 0xF6EFDF),
        danger: NSColor(hex: 0xB23A2E), diagramBase: NSColor(hex: 0xF6EFDF),
        bold: NSColor(hex: 0x000000), heading: NSColor(hex: 0x141414), italic: NSColor(hex: 0x3A3A3A),
        inlineCode: NSColor(hex: 0xA8473A), listMarker: NSColor(hex: 0xB07D2B),
        quote: NSColor(hex: 0x7F6A8A), link: NSColor(hex: 0x2F6F8F))

    static let semanticKeys: [(path: WritableKeyPath<Palette, NSColor?>, name: String)] = [
        (\.bold, "boldColor"), (\.heading, "headingColor"), (\.italic, "italicColor"),
        (\.inlineCode, "inlineCodeColor"), (\.listMarker, "listMarkerColor"),
        (\.quote, "quoteColor"), (\.link, "linkColor"),
    ]

    /// The theme's palette with the user's semantic overrides applied.
    static func resolved(_ kind: ThemeKind) -> Palette {
        var palette = named(kind)
        for (path, name) in semanticKeys {
            guard let stored = AppState.defaults.string(forKey: kind.key(name)) else { continue }
            palette[keyPath: path] = stored == "none" ? nil : NSColor(hexString: stored) ?? palette[keyPath: path]
        }
        return palette
    }
}

/// The current theme's resolved palette. SwiftUI views reading it re-render
/// when it changes; AppKit views refresh on `.themeDidChange`.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()
    private(set) var kind = ThemeKind.current
    private(set) var palette = Palette.resolved(ThemeKind.current)

    func reload() {
        kind = ThemeKind.current
        palette = Palette.resolved(kind)
        NotificationCenter.default.post(name: .themeDidChange, object: nil)
    }
}

extension Notification.Name {
    static let themeDidChange = Notification.Name("CatalogThemeDidChange")
}

/// A view that keeps palette colors where a redraw won't refresh them
/// (layers, labels set up once) and re-applies them on a theme change.
protocol ThemeRefreshing: NSView {
    func applyTheme()
}

extension NSView {
    /// Re-applies the palette throughout this view's subtree and redraws it.
    func refreshTheme() {
        (self as? ThemeRefreshing)?.applyTheme()
        needsDisplay = true
        subviews.forEach { $0.refreshTheme() }
    }
}

/// The current palette, plus fonts and metrics.
enum Theme {
    static var palette: Palette { ThemeStore.shared.palette }

    static var background: NSColor { palette.background }
    static var backgroundOpacity: CGFloat { palette.backgroundOpacity }

    static var foreground: NSColor { palette.foreground }

    /// Overrides the current theme's semantic color; nil is "No color".
    private static func setSemanticColor(_ color: NSColor?, key: String) {
        let key = ThemeKind.current.key(key)
        if let color {
            guard let hex = color.rgbHexString else { return }
            AppState.defaults.set(hex, forKey: key)
        } else {
            AppState.defaults.set("none", forKey: key)
        }
        ThemeStore.shared.reload()
    }

    static var bold: NSColor? {
        get { palette.bold }
        set { setSemanticColor(newValue, key: "boldColor") }
    }
    static var heading: NSColor? {
        get { palette.heading }
        set { setSemanticColor(newValue, key: "headingColor") }
    }
    static var italic: NSColor? {
        get { palette.italic }
        set { setSemanticColor(newValue, key: "italicColor") }
    }
    static var code: NSColor { palette.code }
    static var codeAmber: NSColor? {
        get { palette.inlineCode }
        set { setSemanticColor(newValue, key: "inlineCodeColor") }
    }
    static var dim: NSColor { palette.dim }
    // Translucent secondary chrome; separate from subdued Markdown syntax.
    static var secondary: NSColor { palette.secondary }
    /// Fills drawn at low opacity: white on dark themes, ink on light ones.
    static var wash: NSColor { palette.wash }
    static var listMarker: NSColor? {
        get { palette.listMarker }
        set { setSemanticColor(newValue, key: "listMarkerColor") }
    }
    static var quote: NSColor? {
        get { palette.quote }
        set { setSemanticColor(newValue, key: "quoteColor") }
    }
    static var link: NSColor? {
        get { palette.link }
        set { setSemanticColor(newValue, key: "linkColor") }
    }
    static var cursor: NSColor { palette.cursor }
    static var selection: NSColor { palette.selection }
    static var sidebarSelection: NSColor { palette.sidebarSelection }
    static var codeBackground: NSColor { palette.codeBackground }
    /// Distinct instance so the layout manager can tell block bands from
    /// inline chips when padding background rects (compared by identity).
    static var codeBlockBackground: NSColor { palette.codeBlockBackground }
    static let codeBlockPadding: CGFloat = 12

    static let maxImageWidth: CGFloat = 440
    static let imageCornerRadius: CGFloat = 8

    /// Monospaced font for code, independent of the body family.
    /// (The system monospaced font is SF Mono on modern macOS.)
    static func codeFont(size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static let lineHeightMultiple: CGFloat = 1.16
    static let padding: CGFloat = 28

    /// Text colors offered by the selection toolbar. Serialized to markdown
    /// as inline HTML spans, so files stay portable.
    static let accentColors: [(name: String, hex: String)] = [
        ("Blue", "72A7FF"),
        ("Red", "FF5C5C"),
        ("Green", "55E6A5"),
        ("Lavender", "BF8EE8"),
        ("Orange", "FF9F45"),
        ("Dandelion", "FFD166"),
        ("Leaf Green", "86C56A"),
        ("Coral", "FF8A7A"),
    ]
    static var halfOpacityText: NSColor { foreground.withAlphaComponent(0.5) }
    /// Prose column cap: about half a MacBook screen minus 80pt padding per
    /// side. Past this the window just grows its horizontal padding.
    static let maxTextWidth: CGFloat = 720

    static var fontSize: CGFloat {
        get {
            let stored = AppState.defaults.double(forKey: "fontSize")
            return stored > 0 ? CGFloat(stored) : 20
        }
        set {
            AppState.defaults.set(Double(newValue), forKey: "fontSize")
        }
    }

    static let defaultFontFamily = "Classic Console Neue"

    static var fontFamily: String {
        get { AppState.defaults.string(forKey: "fontFamily") ?? defaultFontFamily }
        set { AppState.defaults.set(newValue, forKey: "fontFamily") }
    }

    /// Font for app chrome: sidebar, tabs, status, pickers, and other custom
    /// interface labels. Existing users inherit their body choice until they
    /// explicitly choose a separate interface family.
    static var interfaceFontFamily: String {
        get { AppState.defaults.string(forKey: "interfaceFontFamily") ?? fontFamily }
        set { AppState.defaults.set(newValue, forKey: "interfaceFontFamily") }
    }

    private static let fallbackFontNames = ["ClassicConsoleNeue", "JetBrainsMono-Regular", "SFMono-Regular", "Menlo"]

    static func font(size: CGFloat) -> NSFont {
        if let font = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: size) {
            return font
        }
        for name in fallbackFontNames {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func interfaceFont(size: CGFloat) -> NSFont {
        if let font = NSFontManager.shared.font(withFamily: interfaceFontFamily,
                                                traits: [], weight: 5, size: size) {
            return font
        }
        return .systemFont(ofSize: size)
    }

    static var baseFont: NSFont { font(size: fontSize) }

    private static var boldCache: [String: (font: NSFont, synthetic: Bool)] = [:]

    /// The family's real bold face when it has one; otherwise the regular
    /// face flagged `synthetic` so callers can fake weight with stroke.
    static func boldFont(size: CGFloat) -> (font: NSFont, synthetic: Bool) {
        let key = "\(fontFamily)#\(size)"
        if let cached = boldCache[key] { return cached }
        let regular = font(size: size)
        let bold = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        let synthetic = !NSFontManager.shared.traits(of: bold).contains(.boldFontMask)
        let result = (synthetic ? regular : bold, synthetic)
        boldCache[key] = result
        return result
    }

    private static var italicCache: [String: (font: NSFont, synthetic: Bool)] = [:]

    /// The family's real italic face; `synthetic` means fake it with skew.
    static func italicFont(size: CGFloat) -> (font: NSFont, synthetic: Bool) {
        let key = "\(fontFamily)#\(size)"
        if let cached = italicCache[key] { return cached }
        let regular = font(size: size)
        let italic = NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)
        let synthetic = !NSFontManager.shared.traits(of: italic).contains(.italicFontMask)
        let result = (synthetic ? regular : italic, synthetic)
        italicCache[key] = result
        return result
    }

    private static var boldItalicCache: [String: (font: NSFont, syntheticBold: Bool, syntheticItalic: Bool)] = [:]

    /// The family's bold-italic face, degrading gracefully: real bold with
    /// synthetic slant, or regular with synthetic weight and slant.
    static func boldItalicFont(size: CGFloat) -> (font: NSFont, syntheticBold: Bool, syntheticItalic: Bool) {
        let key = "\(fontFamily)#\(size)"
        if let cached = boldItalicCache[key] { return cached }
        let (bold, syntheticBold) = boldFont(size: size)
        let combined = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
        let traits = NSFontManager.shared.traits(of: combined)
        let hasItalic = traits.contains(.italicFontMask)
        let hasBold = traits.contains(.boldFontMask) || syntheticBold
        let result: (NSFont, Bool, Bool) = hasItalic && hasBold
            ? (combined, syntheticBold, false)
            : (bold, syntheticBold, true)
        boldItalicCache[key] = result
        return result
    }

    static func paragraphStyle(spacingBefore: CGFloat = 0,
                               spacingAfter: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        return style
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: foreground,
            .paragraphStyle: paragraphStyle(),
        ]
    }
}
