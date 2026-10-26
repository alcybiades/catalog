import AppKit

// The same window-server API WezTerm uses for macos_window_background_blur:
// blurs whatever is behind the window by `radius`, with no material tint —
// the window's own (translucent) background composites over the raw blur.
private typealias CGSConnectionID = UInt32

@_silgen_name("CGSDefaultConnectionForThread")
private func CGSDefaultConnectionForThread() -> CGSConnectionID

@_silgen_name("CGSSetWindowBackgroundBlurRadius")
@discardableResult
private func CGSSetWindowBackgroundBlurRadius(
    _ connection: CGSConnectionID, _ windowNumber: UInt32, _ radius: UInt32
) -> Int32

/// Keep AppKit's window shape and shadow while drawing our own controls.
/// The full-size content view paints right up to that single native clip.
final class CatalogWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Configures `window` to match the WezTerm backdrop: transparent window,
/// background blur radius 30, and a #141414 tint at exactly 0.60 opacity
/// painted by the returned container view (install subviews into it).
/// Opaque themes paint their background solid, without the blur.
@discardableResult
func applyTerminalBackdrop(to window: NSWindow) -> NSView {
    window.isOpaque = false
    window.backgroundColor = .clear
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    if #available(macOS 26.0, *) {
        // Tahoe chooses its larger (26 pt) native outline for unified-toolbar
        // windows. Keep the toolbar empty: our tab row supplies the controls.
        let toolbar = NSToolbar(identifier: "CatalogWindowShape")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        window.titlebarSeparatorStyle = .none
    }
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        window.standardWindowButton(button)?.isHidden = true
    }

    let container = NSView()
    container.wantsLayer = true
    // Do not round the backdrop separately: AppKit clips the tint, content,
    // blur and native edge to the same window outline, including during resize.
    window.contentView = container
    applyThemeBackdrop(to: window)
    return container
}

/// Applies the current theme's appearance, tint, and blur to a window set
/// up by `applyTerminalBackdrop`.
func applyThemeBackdrop(to window: NSWindow) {
    let palette = Theme.palette
    window.appearance = palette.appearance
    window.contentView?.layer?.backgroundColor =
        palette.background.withAlphaComponent(palette.backgroundOpacity).cgColor
    CGSSetWindowBackgroundBlurRadius(
        CGSDefaultConnectionForThread(), UInt32(window.windowNumber), UInt32(palette.blurRadius))
}
