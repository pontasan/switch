import AppKit

/// What the user has chosen about how Switch behaves, kept in the user defaults so that it
/// lasts between launches. Each value is read when it is needed, so a change takes effect at
/// the next switch or the next time the panel is placed.
@MainActor
final class SwitchSettings: NSObject {
    static let title = "Settings"
    static let arrangesWindowsTitle = "Arrange Windows Automatically"
    static let minimizesOtherWindowsTitle = "Minimize Other Windows"
    static let centersPanelTitle = "Show Panel in Center of Display"

    private static let arrangesWindowsKey = "arrangesWindows"
    private static let minimizesOtherWindowsKey = "minimizesOtherWindows"
    private static let centersPanelKey = "centersPanel"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Self.arrangesWindowsKey: true,
            Self.minimizesOtherWindowsKey: true,
            Self.centersPanelKey: false
        ])
    }

    /// Chosen windows take the size and place of equal columns. Off, they stay as they are.
    var arrangesWindows: Bool { defaults.bool(forKey: Self.arrangesWindowsKey) }
    /// The chosen application's other windows go to the Dock. Off, they stay behind the chosen ones.
    var minimizesOtherWindows: Bool { defaults.bool(forKey: Self.minimizesOtherWindowsKey) }
    /// The panel opens in the center of the display. Off, it opens below the menu bar icon.
    var centersPanel: Bool { defaults.bool(forKey: Self.centersPanelKey) }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: Self.title)
        menu.addItem(toggleItem(Self.arrangesWindowsTitle, isOn: arrangesWindows, action: #selector(toggleArrangesWindows)))
        menu.addItem(toggleItem(Self.minimizesOtherWindowsTitle, isOn: minimizesOtherWindows, action: #selector(toggleMinimizesOtherWindows)))
        menu.addItem(toggleItem(Self.centersPanelTitle, isOn: centersPanel, action: #selector(toggleCentersPanel)))
        return menu
    }

    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: Self.title, action: nil, keyEquivalent: "")
        item.submenu = makeMenu()
        return item
    }

    private func toggleItem(_ title: String, isOn: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        return item
    }

    @objc func toggleArrangesWindows() {
        defaults.set(!arrangesWindows, forKey: Self.arrangesWindowsKey)
    }

    @objc func toggleMinimizesOtherWindows() {
        defaults.set(!minimizesOtherWindows, forKey: Self.minimizesOtherWindowsKey)
    }

    @objc func toggleCentersPanel() {
        defaults.set(!centersPanel, forKey: Self.centersPanelKey)
    }
}
