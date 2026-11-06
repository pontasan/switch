import AppKit

/// Applications the user has turned Switch off for. Switch leaves them alone: the shortcut is
/// left to macOS while one of them is in front, and the panel does nothing with its windows.
/// Every application is on until turned off. Stored by the same identifier as the pins, so
/// that it lasts across launches of both Switch and the application.
@MainActor
final class DisabledApplications {
    private static let key = "disabledApplications"
    private let defaults: UserDefaults
    private var identifiers: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        identifiers = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isEnabled(_ identifier: String) -> Bool {
        !identifiers.contains(identifier)
    }

    func setEnabled(_ enabled: Bool, for identifier: String) {
        if enabled {
            identifiers.remove(identifier)
        } else {
            identifiers.insert(identifier)
        }
        defaults.set(identifiers.sorted(), forKey: Self.key)
    }

    /// The identifier a listed application has for this running one (`ListedApplication.identifier`).
    static func identifier(of application: NSRunningApplication) -> String {
        application.bundleIdentifier ?? application.localizedName ?? ""
    }
}
