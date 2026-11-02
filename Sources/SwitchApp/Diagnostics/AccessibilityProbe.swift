#if DEBUG
import AppKit
import ApplicationServices

/// Debug-only, read-only survey of what the Accessibility API exposes.
///
/// Run through LaunchServices so that the permission check applies to Switch
/// itself rather than to the launching process:
///   open -n .build/Switch.app --args --ax-probe /path/to/output.json
///
/// It changes no window. Window titles are never read, so the report holds only
/// application names, counts, and window capabilities.
enum AccessibilityProbe {
    static let argument = "--ax-probe"

    static func outputPath(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: argument) else { return nil }
        let valueIndex = arguments.index(after: index)
        precondition(valueIndex < arguments.endIndex, "\(argument) requires an output path")
        return arguments[valueIndex]
    }

    struct WindowReport: Encodable, Equatable {
        let role: String?
        let subrole: String?
        let minimized: Bool?
        let minimizedSettable: Bool
        let canRaise: Bool
        let positionSettable: Bool
        let sizeSettable: Bool
        /// kAXDocumentAttribute, a file URL that some applications publish.
        let document: String?
        let frame: [Double]?
    }

    struct ApplicationReport: Encodable, Equatable {
        let name: String
        let bundleIdentifier: String?
        let axErrorCode: Int32
        let axWindows: [WindowReport]
        /// Layer 0 windows at least 100 points on each side, from CGWindowList.
        let cgWindowCount: Int
        let cgOnScreenCount: Int
    }

    struct Report: Encodable {
        let trusted: Bool
        let applications: [ApplicationReport]
    }

    static func run(outputPath: String) {
        // Shows the system prompt that leads to the permission setting if needed.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        let applications = trusted ? surveyApplications() : []
        let report = Report(trusted: trusted,
                            applications: applications)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(report).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        } catch {
            fatalError("Cannot write \(outputPath): \(error)")
        }
    }

    private static func surveyApplications() -> [ApplicationReport] {
        guard let cgWindows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            fatalError("CGWindowListCopyWindowInfo returned no list")
        }
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map { application in
                let pid = application.processIdentifier
                let element = AXUIElementCreateApplication(pid)
                var windowsValue: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsValue)
                let windows = (windowsValue as? [AXUIElement]) ?? []
                let owned = cgWindows.filter { isDocumentSizedWindow($0, ownedBy: pid) }
                return ApplicationReport(
                    name: application.localizedName ?? "-",
                    bundleIdentifier: application.bundleIdentifier,
                    axErrorCode: error.rawValue,
                    axWindows: windows.map(windowReport),
                    cgWindowCount: owned.count,
                    cgOnScreenCount: owned.filter { ($0[kCGWindowIsOnscreen as String] as? Bool) == true }.count
                )
            }
    }

    private static func isDocumentSizedWindow(_ window: [String: Any], ownedBy pid: pid_t) -> Bool {
        guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
              (window[kCGWindowLayer as String] as? Int) == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
              let width = bounds["Width"], let height = bounds["Height"] else {
            return false
        }
        return width >= 100 && height >= 100
    }

    private static func windowReport(_ window: AXUIElement) -> WindowReport {
        var settable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &settable)
        var actions: CFArray?
        AXUIElementCopyActionNames(window, &actions)
        return WindowReport(
            role: attribute(window, kAXRoleAttribute) as? String,
            subrole: attribute(window, kAXSubroleAttribute) as? String,
            minimized: attribute(window, kAXMinimizedAttribute) as? Bool,
            minimizedSettable: settableError == .success && settable.boolValue,
            canRaise: ((actions as? [String]) ?? []).contains(kAXRaiseAction),
            positionSettable: isSettable(window, kAXPositionAttribute),
            sizeSettable: isSettable(window, kAXSizeAttribute),
            document: attribute(window, kAXDocumentAttribute) as? String,
            frame: frame(of: window)
        )
    }

    private static func frame(of window: AXUIElement) -> [Double]? {
        guard let position = attribute(window, kAXPositionAttribute), let size = attribute(window, kAXSizeAttribute) else {
            return nil
        }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else {
            return nil
        }
        return [point.x, point.y, extent.width, extent.height].map(Double.init)
    }

    private static func isSettable(_ window: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(window, name as CFString, &settable) == .success && settable.boolValue
    }

    private static func attribute(_ window: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, name as CFString, &value)
        return value
    }
}
#endif
