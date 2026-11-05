import AppKit

/// The standard About panel, with the version from the bundle. The app has no menu bar of
/// its own to offer this from, and is not active, so it has to come forward first.
@MainActor
final class AboutPanel: NSObject {
    static let shared = AboutPanel()

    /// The version once. Left to itself the panel can add the build in brackets, and here
    /// both are the same number.
    static func options(info: [String: Any]?) -> [NSApplication.AboutPanelOptionKey: Any] {
        [.applicationVersion: info?["CFBundleShortVersionString"] as? String ?? "", .version: ""]
    }

    @objc func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: Self.options(info: Bundle.main.infoDictionary))
    }
}

/// The Switch icon in the system menu bar. A left click opens the window panel,
/// and a right click offers About and Quit, because the app has no Dock icon.
@MainActor
final class MenuBarController: NSObject {
    static let quitTitle = "Quit Switch"
    static let aboutTitle = "About Switch"

    private let statusItem: NSStatusItem
    private let onClick: (NSRect) -> Void
    private let launchAtLogin: LaunchAtLogin?
    private let settings: SwitchSettings?

    init(statusBar: NSStatusBar = .system, launchAtLogin: LaunchAtLogin? = nil, settings: SwitchSettings? = nil, onClick: @escaping (NSRect) -> Void) {
        self.launchAtLogin = launchAtLogin
        self.settings = settings
        statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        self.onClick = onClick
        super.init()
        guard let button = statusItem.button else {
            preconditionFailure("Status item has no button")
        }
        button.image = Self.icon()
        button.toolTip = "Switch"
        button.target = self
        button.action = #selector(buttonClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    static func makeMenu(launchAtLogin: LaunchAtLogin? = nil, settings: SwitchSettings? = nil) -> NSMenu {
        let menu = NSMenu(title: "Switch")
        let aboutItem = NSMenuItem(title: aboutTitle, action: #selector(AboutPanel.show), keyEquivalent: "")
        aboutItem.target = AboutPanel.shared
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        if let settings {
            menu.addItem(settings.makeMenuItem())
        }
        if let launchAtLogin {
            menu.addItem(launchAtLogin.makeMenuItem())
        }
        if settings != nil || launchAtLogin != nil {
            menu.addItem(.separator())
        }
        let quitItem = NSMenuItem(title: quitTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApplication.shared
        menu.addItem(quitItem)
        return menu
    }

    @objc private func buttonClicked() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            // Assigning a menu makes every click open it, so it is set only for this one.
            statusItem.menu = Self.makeMenu(launchAtLogin: launchAtLogin, settings: settings)
            button.performClick(nil)
            statusItem.menu = nil
            return
        }
        clickForTesting()
    }

    /// Where the icon is on screen, which is what the panel opens below.
    var anchor: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func clickForTesting() {
        guard let anchor else { return }
        onClick(anchor)
    }

    var imageForTesting: NSImage? { statusItem.button?.image }
    var buttonForTesting: NSStatusBarButton? { statusItem.button }

    func invalidate() {
        statusItem.statusBar?.removeStatusItem(statusItem)
    }

    /// A template image, so macOS tints it to match the menu bar on every
    /// display and appearance.
    private static func icon() -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            // The S-shaped bolt from Resources/Icon/AppIcon.svg, on a 100-unit grid.
            let points: [(CGFloat, CGFloat)] = [
                (90, 6), (20, 30), (14, 44), (58, 56), (10, 94), (80, 70), (86, 56), (42, 44)
            ]
            let path = NSBezierPath()
            for (index, point) in points.enumerated() {
                let location = NSPoint(x: point.0 * side / 100, y: point.1 * side / 100)
                if index == 0 { path.move(to: location) } else { path.line(to: location) }
            }
            path.close()
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Switch"
        return image
    }
}
