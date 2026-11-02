import Foundation

/// Applications the user keeps at the top of the list, and windows kept at the top of an
/// application's list. Applications are stored by bundle identifier, so a pin lasts across
/// launches of both Switch and the application.
@MainActor
final class PinnedApplications {
    private static let key = "pinnedApplications"
    private static let windowsKey = "pinnedWindows"
    private let defaults: UserDefaults
    private var identifiers: Set<String>
    private var windows: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        identifiers = Set(defaults.stringArray(forKey: Self.key) ?? [])
        windows = Set(defaults.stringArray(forKey: Self.windowsKey) ?? [])
    }

    func contains(_ identifier: String) -> Bool {
        identifiers.contains(identifier)
    }

    func toggle(_ identifier: String) {
        if identifiers.remove(identifier) == nil {
            identifiers.insert(identifier)
        }
        defaults.set(identifiers.sorted(), forKey: Self.key)
    }

    /// Pinned applications first, each with its pinned windows first. Within each group the
    /// given order stays.
    func ordered(_ applications: [ListedApplication]) -> [ListedApplication] {
        let windowsOrdered = applications.map { application -> ListedApplication in
            var ordered = application
            ordered.windows = windowOrder(of: application).map { application.windows[$0] }
            return ordered
        }
        return windowsOrdered.filter { contains($0.identifier) } + windowsOrdered.filter { !contains($0.identifier) }
    }

    /// Two applications can have windows with the same name.
    private static func windowKey(_ key: String, of application: String) -> String {
        application + "\u{0}" + key
    }

    func containsWindow(_ key: String, of application: String) -> Bool {
        windows.contains(Self.windowKey(key, of: application))
    }

    func toggleWindow(_ key: String, of application: String) {
        let stored = Self.windowKey(key, of: application)
        if windows.remove(stored) == nil {
            windows.insert(stored)
        }
        defaults.set(windows.sorted(), forKey: Self.windowsKey)
    }

    /// Where each row of the list goes: pinned rows move to the top of their own section, so
    /// a terminal stays under its workspace and a window with a path stays with the others.
    func windowOrder(of application: ListedApplication) -> [Int] {
        var order: [Int] = []
        var start = 0
        let rows = application.windows
        while start < rows.count {
            var end = start
            while end < rows.count, rows[end].section == rows[start].section { end += 1 }
            let part = Array(start..<end)
            let isPinned = { (row: Int) in self.containsWindow(rows[row].pinKey, of: application.identifier) }
            order += part.filter(isPinned) + part.filter { !isPinned($0) }
            start = end
        }
        return order
    }
}
