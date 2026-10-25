import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    // NSApplication holds its delegate weakly.
    withExtendedLifetime(delegate) { app.run() }
}
