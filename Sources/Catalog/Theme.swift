import AppKit

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

/// "Neon Noir" — mirrors ~/.wezterm.lua.
enum Theme {
    static let background = NSColor(hex: 0x141414)
    static let backgroundOpacity: CGFloat = 0.60

    static let foreground = NSColor(hex: 0x63D0FF)
    private static func semanticColor(_ key: String, fallback: UInt32) -> NSColor? {
        guard let stored = AppState.defaults.string(forKey: key) else { return NSColor(hex: fallback) }
        if stored == "none" { return nil }
        return NSColor(hexString: stored) ?? NSColor(hex: fallback)
    }

    private static func setSemanticColor(_ color: NSColor?, key: String) {
        guard let color else { AppState.defaults.set("none", forKey: key); return }
        if let hex = color.rgbHexString { AppState.defaults.set(hex, forKey: key) }
    }

    static var bold: NSColor? {
        get { semanticColor("boldColor", fallback: 0xFFFFFF) }
        set { setSemanticColor(newValue, key: "boldColor") }
    }
    static var heading: NSColor? {
        get { semanticColor("headingColor", fallback: 0xA4BEEF) }
        set { setSemanticColor(newValue, key: "headingColor") }
    }
    static var italic: NSColor? {
        get { semanticColor("italicColor", fallback: 0xD7E0FF) }
        set { setSemanticColor(newValue, key: "italicColor") }
    }
    static let code = NSColor(hex: 0x55E6A5)
    static var codeAmber: NSColor? {
        get { semanticColor("inlineCodeColor", fallback: 0xFFB86C) }
        set { setSemanticColor(newValue, key: "inlineCodeColor") }
    }
    static let dim = NSColor(hex: 0x526078)
    // Translucent secondary chrome; separate from subdued Markdown syntax.
    static let secondary = NSColor.white.withAlphaComponent(0.5)
    static var listMarker: NSColor? {
        get { semanticColor("listMarkerColor", fallback: 0xFFD166) }
        set { setSemanticColor(newValue, key: "listMarkerColor") }
    }
    static var quote: NSColor? {
        get { semanticColor("quoteColor", fallback: 0xBF8EE8) }
        set { setSemanticColor(newValue, key: "quoteColor") }
    }
    static var link: NSColor? {
        get { semanticColor("linkColor", fallback: 0x7DD3FC) }
        set { setSemanticColor(newValue, key: "linkColor") }
    }
    static let cursor = NSColor(hex: 0x727272)
    static let selection = NSColor(hex: 0x334A7D)
    static let sidebarSelection = NSColor(hex: 0x7186A5, alpha: 0.28)
    static let codeBackground = NSColor(hex: 0x2E2E2E, alpha: 0.5)
    /// Distinct instance so the layout manager can tell block bands from
    /// inline chips when padding background rects (compared by identity).
    static let codeBlockBackground = NSColor(hex: 0x2E2E2E, alpha: 0.5)
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
    static let halfOpacityText = foreground.withAlphaComponent(0.5)
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
