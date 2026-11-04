#if DEBUG
import AppKit

/// Debug-only: writes the panel with sample contents to PNG files, light and dark.
///
///   open -n -W .build/Switch.app --args --panel-image /path/to/prefix
@MainActor
enum PanelImage {
    private final class NoApplication: ManagedApplication {
        func windows() -> [ManagedWindow] { [] }
        func focusedWindow() -> ManagedWindow? { nil }
        var isFrontmost: Bool { false }
        func activate() {}
        func terminate() -> Bool { true }
        var isTerminated: Bool { false }
        var questionCount: Int { 0 }
    }

    private final class NoWindow: ManagedWindow {
        let isMinimized = false
        let isFullScreen = false
        let exists = true
        func isSame(as other: ManagedWindow) -> Bool { false }
        func setMinimized(_ minimized: Bool) throws {}
        func raise() throws {}
        func setFrame(_ frame: CGRect) throws {}
    }

    static func write(to prefix: String) {
        guard let defaults = UserDefaults(suiteName: "com.tranworks.switch.panel-image") else { return }
        defaults.removePersistentDomain(forName: "com.tranworks.switch.panel-image")
        let pins = PinnedApplications(defaults: defaults)
        pins.toggle("com.microsoft.VSCode")
        let icon = { (path: String) in NSWorkspace.shared.icon(forFile: path) }
        func application(_ name: String, _ bundle: String, _ path: String, _ titles: [String], withoutPath: [String] = []) -> ListedApplication {
            ListedApplication(name: name, icon: icon(path),
                              windows: titles.enumerated().map { index, title in
                                  ListedWindow(title: title, toolTip: nil, isMinimized: index == 3, selection: .direct(NoWindow()),
                                               isFrontmost: index == 1)
                              } + withoutPath.map { title in
                                  ListedWindow(title: title, toolTip: nil, isMinimized: false, selection: .direct(NoWindow()), isWithoutPath: true)
                              },
                              problem: nil, application: NoApplication(), bundleIdentifier: bundle)
        }
        let list = [
            application("Google Chrome", "com.google.Chrome", "/Applications/Google Chrome.app", ["Pull requests", "Documentation"]),
            application("Finder", "com.apple.finder", "/System/Library/CoreServices/Finder.app", ["Downloads", "Applications"]),
            application("Microsoft Excel", "com.microsoft.Excel", "/Applications/Microsoft Excel.app", ["Budget.xlsx"]),
            application("Terminal", "com.apple.Terminal", "/System/Applications/Utilities/Terminal.app", ["zsh"]),
            application("Code", "com.microsoft.VSCode", "/Applications/Visual Studio Code.app",
                        ["alpha-app", "golf-task", "kilo-app", "mike-web", "orange-app", "papa-ai", "server", "sierra-ai"],
                        withoutPath: ["Welcome", "main.py — server [SSH: host]"])
        ]
        let panel = WindowPanelController(onApply: { _, _ in }, onRequestPermission: {}, onQuit: {}, pins: pins)
        panel.reload(applications: list, hasPermission: true, frontmostName: "Code")
        panel.clickWindow(row: 6, shift: true)
        panel.clickWindow(row: 2, shift: true)
        render(panel, to: prefix)
        // The same panel with the switching keys on a row.
        panel.reload(applications: list, hasPermission: true, frontmostName: "Code")
        panel.setKeyboardRowForTesting(2)
        render(panel, to: prefix + "-keys")
        defaults.removePersistentDomain(forName: "com.tranworks.switch.panel-image")
    }

    private static func render(_ panel: WindowPanelController, to prefix: String) {
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            guard let look = NSAppearance(named: appearance),
                  let bitmap = panel.renderForTesting(appearance: look, height: 410) else { continue }
            let image = NSImage(size: bitmap.size)
            image.lockFocus()
            let backdrop = name == "dark" ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.95, alpha: 1)
            backdrop.setFill()
            NSRect(origin: .zero, size: bitmap.size).fill()
            bitmap.draw(in: NSRect(origin: .zero, size: bitmap.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
        }
    }
}
#endif
