import AppKit
import ServiceManagement
import os

/// What macOS keeps about this application as a login item.
protocol LoginItem {
    var isEnabled: Bool { get }
    var needsApproval: Bool { get }
    func register() throws
    func unregister() throws
}

struct MainApplicationLoginItem: LoginItem {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Switch sits in the menu bar all the time, so it starts at login unless the user says not
/// to. It turns itself on once only: after that the user's choice stands, wherever it was made.
@MainActor
final class LaunchAtLogin: NSObject {
    static let title = "Launch at Login"
    private static let key = "launchAtLoginWasSetUp"
    private static let log = Logger(subsystem: "com.tranworks.switch", category: "launch")

    private let item: LoginItem
    private let defaults: UserDefaults
    private let onFailure: (String) -> Void

    init(item: LoginItem = MainApplicationLoginItem(),
         defaults: UserDefaults = .standard,
         onFailure: @escaping (String) -> Void = { _ in }) {
        self.item = item
        self.defaults = defaults
        self.onFailure = onFailure
    }

    var isEnabled: Bool { item.isEnabled }

    func setUpOnFirstLaunch() {
        if !defaults.bool(forKey: Self.key) {
            defaults.set(true, forKey: Self.key)
            do {
                try item.register()
            } catch {
                Self.log.error("cannot start at login: \(error.localizedDescription, privacy: .public)")
            }
        }
        Self.log.notice("start at login: enabled \(self.item.isEnabled), needs approval \(self.item.needsApproval)")
    }

    func makeMenuItem() -> NSMenuItem {
        let menuItem = NSMenuItem(title: Self.title, action: #selector(toggle), keyEquivalent: "")
        menuItem.target = self
        menuItem.state = isEnabled ? .on : .off
        return menuItem
    }

    @objc func toggle() {
        do {
            if item.isEnabled {
                try item.unregister()
            } else if item.needsApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else {
                try item.register()
            }
        } catch {
            onFailure("Could not change Launch at Login: \(error.localizedDescription)")
        }
    }
}
