import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Test runs stay out of the Dock and never take focus from the user's work.
    app.setActivationPolicy(AppState.isTesting ? .accessory : .regular)
    // NSApplication holds its delegate weakly.
    withExtendedLifetime(delegate) { app.run() }
}
