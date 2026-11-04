import AppKit
import ApplicationServices

struct AccessibilityActionError: LocalizedError, Equatable {
    let action: String
    let code: Int32
    var errorDescription: String? { "Could not \(action) a window (Accessibility error \(code))." }

    /// The application could not answer yet. Word does this while its windows come back
    /// from the Dock, after they have stopped reporting themselves as minimized (measured).
    var meansBusy: Bool { code == AXError.cannotComplete.rawValue }
}

/// Private, and the one way to tie an Accessibility window to the window server: the public
/// interfaces share no identifier. Using it was the user's decision, because matching
/// windows by where they are fails whenever two share a place.
@_silgen_name("_AXUIElementGetWindow")
private func axElementGetWindow(_ element: AXUIElement, _ number: UnsafeMutablePointer<CGWindowID>) -> AXError

final class AccessibilityWindow: ManagedWindow {
    let element: AXUIElement

    init(element: AXUIElement) {
        self.element = element
    }

    var title: String? { Self.attribute(element, kAXTitleAttribute) as? String }

    private let numberLock = NSLock()
    private var knownNumber: Int?

    /// The window server's number for this window, which it keeps for as long as it exists.
    /// Asking waits for the application, for over half a second while it is animating
    /// (measured), and the switching keys need the answer at once. So it is asked once, away
    /// from the main thread, when the windows are read.
    var number: Int? {
        if let known = numberLock.withLock({ knownNumber }) { return known }
        var number: CGWindowID = 0
        guard axElementGetWindow(element, &number) == .success else { return nil }
        numberLock.withLock { knownNumber = Int(number) }
        return Int(number)
    }

    var isMinimized: Bool { (Self.attribute(element, kAXMinimizedAttribute) as? Bool) == true }
    var isFullScreen: Bool { (Self.attribute(element, "AXFullScreen") as? Bool) == true }

    var exists: Bool {
        // A process that has gone answers "cannot complete", the same as a busy one, so
        // that answer alone does not say whether the window still exists.
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, kill(pid, 0) == 0 else { return false }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) != .invalidUIElement
    }

    var frame: CGRect? {
        // An application answers with whatever it likes, so the types are checked.
        guard let position = Self.attribute(element, kAXPositionAttribute),
              let size = Self.attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            return nil
        }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else {
            return nil
        }
        return CGRect(origin: origin, size: extent)
    }

    func isSame(as other: ManagedWindow) -> Bool {
        guard let other = other as? AccessibilityWindow else { return false }
        return CFEqual(element, other.element)
    }

    func setMinimized(_ minimized: Bool) throws {
        try check(AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, minimized as CFBoolean),
                  action: minimized ? "minimize" : "restore")
    }

    func raise() throws {
        try check(AXUIElementPerformAction(element, kAXRaiseAction as CFString), action: "raise")
    }

    func setFrame(_ frame: CGRect) throws {
        var origin = frame.origin
        var size = frame.size
        guard let originValue = AXValueCreate(.cgPoint, &origin), let sizeValue = AXValueCreate(.cgSize, &size) else {
            preconditionFailure("AXValueCreate rejected a CGPoint or CGSize")
        }
        try check(AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, originValue), action: "move")
        try check(AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue), action: "resize")
        // A window kept on screen while it was still large may have landed elsewhere.
        try check(AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, originValue), action: "move")
    }

    private func check(_ error: AXError, action: String) throws {
        guard error == .success else {
            throw AccessibilityActionError(action: action, code: error.rawValue)
        }
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }
}

final class AccessibilityApplication: ManagedApplication {
    /// kAXWindowsAttribute also returns other things: Finder lists an AXScrollArea,
    /// and Chrome lists AXUnknown windows that cannot be minimized.
    private static let listedSubroles: Set<String> = [kAXStandardWindowSubrole as String, kAXDialogSubrole as String]

    private let application: NSRunningApplication
    private let element: AXUIElement

    init(application: NSRunningApplication) {
        self.application = application
        element = AXUIElementCreateApplication(application.processIdentifier)
    }

    var processIdentifier: pid_t { application.processIdentifier }

    func accessibilityWindows() -> [AccessibilityWindow] {
        let windows = (AccessibilityWindow.attribute(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return windows.filter(Self.isListed).map(AccessibilityWindow.init(element:))
    }

    /// The windows as rows, or nil when the application did not answer. An application busy
    /// with something else, such as minimizing, cannot say what it has, which is not the
    /// same as having nothing.
    func windowRows() -> [ListedWindow]? {
        func read(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
            var value: CFTypeRef?
            switch AXUIElementCopyAttributeValue(element, name as CFString, &value) {
            case .success: return value
            // A window closed during the reading, or an application that has just quit.
            case .noValue, .attributeUnsupported, .invalidUIElement: return nil
            default: throw AccessibilityActionError(action: "read", code: AXError.cannotComplete.rawValue)
            }
        }
        do {
            let windows = (try read(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            return try windows.compactMap { window in
                guard (try read(window, kAXRoleAttribute) as? String) == (kAXWindowRole as String),
                      let subrole = try read(window, kAXSubroleAttribute) as? String,
                      Self.listedSubroles.contains(subrole) else { return nil }
                var settable = DarwinBoolean(false)
                let answer = AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &settable)
                if answer == .cannotComplete { throw AccessibilityActionError(action: "read", code: answer.rawValue) }
                guard answer == .success, settable.boolValue else { return nil }
                let title = try read(window, kAXTitleAttribute) as? String ?? ""
                return ListedWindow(title: title.isEmpty ? WindowListing.untitledWindowTitle : title,
                                    toolTip: nil,
                                    isMinimized: (try read(window, kAXMinimizedAttribute) as? Bool) == true,
                                    selection: .direct(AccessibilityWindow(element: window)))
            }
        } catch {
            return nil
        }
    }

    func windows() -> [ManagedWindow] { accessibilityWindows() }

    func focusedWindow() -> ManagedWindow? {
        guard let value = AccessibilityWindow.attribute(element, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return AccessibilityWindow(element: value as! AXUIElement)
    }

    var isFrontmost: Bool {
        (AccessibilityWindow.attribute(element, kAXFrontmostAttribute) as? Bool) == true
    }

    func activate() {
        application.activate()
    }

    func terminate() -> Bool {
        application.terminate()
    }

    var isTerminated: Bool { application.isTerminated }

    var questionCount: Int {
        let windows = (AccessibilityWindow.attribute(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return windows.reduce(0) { count, window in
            let subrole = AccessibilityWindow.attribute(window, kAXSubroleAttribute) as? String
            let isDialog = subrole == (kAXDialogSubrole as String) || subrole == (kAXSystemDialogSubrole as String)
            let children = (AccessibilityWindow.attribute(window, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            let sheets = children.filter { (AccessibilityWindow.attribute($0, kAXRoleAttribute) as? String) == "AXSheet" }.count
            return count + (isDialog ? 1 : 0) + sheets
        }
    }

    private static func isListed(_ window: AXUIElement) -> Bool {
        guard (AccessibilityWindow.attribute(window, kAXRoleAttribute) as? String) == (kAXWindowRole as String),
              let subrole = AccessibilityWindow.attribute(window, kAXSubroleAttribute) as? String,
              listedSubroles.contains(subrole) else {
            return false
        }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &settable) == .success
            && settable.boolValue
    }
}
