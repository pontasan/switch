import AppKit

// Switch - macOS menu bar window switcher
//
// Entry point. The app has no Dock icon or main window (LSUIElement).

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    // NSApplication holds its delegate weakly.
    withExtendedLifetime(appDelegate) {
        application.run()
    }
}
