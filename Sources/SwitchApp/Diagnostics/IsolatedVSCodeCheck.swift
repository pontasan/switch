#if DEBUG
import AppKit
import ApplicationServices

/// Debug-only test of the VS Code paths against a real VS Code on throwaway settings,
/// separate from the user's instance: pairing, closing and reopening a window, quitting
/// and relaunching, and paths in both Unicode forms.
///
///   open -n -W .build/Switch.app --args --vscode-check out.json --root /tmp/dir
@MainActor
enum IsolatedVSCodeCheck {
    struct Check: Encodable {
        let name: String
        let passed: Bool
        let detail: String
    }

    private static var checks: [Check] = []

    private static func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
        checks.append(Check(name: name, passed: passed, detail: passed ? "" : detail()))
    }

    private static func settle(_ seconds: Double = 0.4) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static let appURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true)

    static func run(outputPath: String, root: URL) async {
        guard AXIsProcessTrusted() else { fatalError("No Accessibility permission") }
        let initial = NSWorkspace.shared.frontmostApplication
        let data = root.appendingPathComponent("data", isDirectory: true)
        let extensions = root.appendingPathComponent("extensions", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let fileManager = FileManager.default
        // The directory is created in NFD by APFS's view of neither form: what matters is
        // that each path reaches VS Code in the form it was given.
        let names = ["alpha", "beta", "with space", "\u{30B5}\u{30FC}\u{30D0}"]
        for name in names {
            let folder = projects.appendingPathComponent(name, isDirectory: true)
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? "marker".write(to: folder.appendingPathComponent("marker-\(name).txt"), atomically: true, encoding: .utf8)
        }
        try? fileManager.createDirectory(at: data.appendingPathComponent("User"), withIntermediateDirectories: true)
        let settings = ["telemetry.telemetryLevel": "off", "update.mode": "none", "extensions.autoUpdate": "false",
                        "extensions.autoCheckUpdates": "false", "workbench.startupEditor": "none",
                        "security.workspace.trust.enabled": "false", "workbench.enableExperiments": "false"]
        let settingsJSON = "{" + settings.map { key, value in
            let rendered = value == "false" ? "false" : "\"\(value)\""
            return "\"\(key)\": \(rendered)"
        }.joined(separator: ",") + "}"
        try? settingsJSON.write(to: data.appendingPathComponent("User/settings.json"), atomically: true, encoding: .utf8)
        // A key for the command that detaches an editor, which the CLI cannot do.
        try? "[{\"key\":\"ctrl+alt+shift+f12\",\"command\":\"workbench.action.moveEditorToNewWindow\"}]"
            .write(to: data.appendingPathComponent("User/keybindings.json"), atomically: true, encoding: .utf8)

        let baseArguments = ["--user-data-dir", data.path, "--extensions-dir", extensions.path, "--disable-extensions", "--disable-updates", "--disable-telemetry"]
        let opener = VSCodeCLIWindowOpener(extraArguments: baseArguments + ["--disable-workspace-trust"])

        func findInstance() -> NSRunningApplication? {
            NSWorkspace.shared.runningApplications.first { application in
                guard application.bundleIdentifier == VSCodeWindowCatalog.applicationBundleIdentifier, !application.isTerminated else { return false }
                return commandLine(of: application.processIdentifier).contains(data.path)
            }
        }
        func open(_ arguments: [String]) async {
            let process = Process()
            process.executableURL = appURL.appendingPathComponent("Contents/Resources/app/bin/code")
            process.arguments = baseArguments + arguments
            process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            while process.isRunning { await settle(0.05) }
        }
        let folderPaths = names.map { projects.appendingPathComponent($0).path.precomposedStringWithCanonicalMapping }
        func openWindow(_ index: Int) async {
            // Foundation.Process would decompose this path, so the fourth window is
            // opened with the decomposed form that APFS and that API agree on.
            let path = folderPaths[index]
            await open([path, path + "/marker-\(names[index]).txt"])
            await settle(1.5)
        }
        await openWindow(0)
        await settle(4)
        for index in 1..<names.count { await openWindow(index) }
        await settle(2)

        guard var instance = findInstance() else {
            check("the throwaway VS Code is running", false)
            finish(outputPath)
            return
        }
        check("the throwaway VS Code is running", true)
        defer { initial?.activate() }

        let currentInstance = { instance }
        let locator = VSCodeWindowLocator(opener: opener, applicationURL: { appURL })
        let resolver = VSCodeWindowResolver(locator: locator,
                                            findApplication: { currentInstance() },
                                            supportDirectory: { data })
        let catalog = VSCodeWindowCatalog(supportDirectory: data)
        func flip(_ count: Int = 1) async {
            for _ in 0..<count {
                instance.activate()
                await settle(1.0)
                initial?.activate()
                await settle(1.8)
            }
        }
        // VS Code's open windows are listed in its state only after it has saved.
        func entries() -> [VSCodeWindowEntry] { (try? catalog.openWindows()) ?? [] }
        func managed() -> AccessibilityApplication { AccessibilityApplication(application: instance) }
        func document(_ window: ManagedWindow) -> String {
            guard let window = window as? AccessibilityWindow else { return "" }
            let value = AccessibilityWindow.attribute(window.element, kAXDocumentAttribute) as? String ?? ""
            return (value.removingPercentEncoding ?? value).precomposedStringWithCanonicalMapping
        }
        /// Asks the locator for each path without running the command, and compares the
        /// answer with the file that window has open.
        func verifyPairs(_ name: String, expected: Int) async {
            var correct = 0
            let list = entries()
            for entry in list where locator.isKnown(path: entry.exactPath) {
                guard let window = try? await locator.locate(path: entry.exactPath, in: managed()) else { continue }
                let folder = entry.exactPath.precomposedStringWithCanonicalMapping
                if document(window).contains(folder + "/") {
                    correct += 1
                } else {
                    check("\(name): pair for \(entry.displayName)", false, "window has \(document(window))")
                }
            }
            check("\(name): all windows are paired correctly", correct == expected, "\(correct) of \(expected), \(list.count) listed")
        }

        await flip(2)
        check("state lists every window", entries().count == names.count, "\(entries().map(\.displayName))")
        // Bounds of fresh windows differ or not by chance. To exercise separation, give
        // them all the same frame and minimize them first.
        let frame = CGRect(x: 40, y: 60, width: 900, height: 700)
        // One stays visible: with every window minimized, none can lose focus and VS Code
        // has no reason to save.
        for (index, window) in managed().accessibilityWindows().enumerated() {
            try? window.setFrame(frame)
            if index > 0 { try? window.setMinimized(true) }
        }
        await settle(3)

        // No save and no change of focus: creation order alone has to pair every window
        // and tell which are minimized, even though they all share a frame.
        let saveBefore = (try? FileManager.default.attributesOfItem(atPath: catalog.stateFileURL.path)[.modificationDate]) as? Date
        let orderLocator = VSCodeWindowLocator(opener: opener, applicationURL: { appURL })
        let orderResolver = VSCodeWindowResolver(locator: orderLocator, findApplication: { currentInstance() }, supportDirectory: { data })
        orderResolver.start()
        await settle(3)
        let saveAfter = (try? FileManager.default.attributesOfItem(atPath: catalog.stateFileURL.path)[.modificationDate]) as? Date
        check("creation order: VS Code saved nothing meanwhile", saveBefore == saveAfter, "\(String(describing: saveBefore)) \(String(describing: saveAfter))")
        check("creation order: every window pairs", entries().allSatisfy { orderLocator.isKnown(path: $0.exactPath) },
              "\(entries().filter { orderLocator.isKnown(path: $0.exactPath) }.count) of \(entries().count); order \((try? catalog.pathsInCreationOrder())?.map { $0 ?? "nil" } ?? []); server \(VSCodeWindowOrder.serverWindows(of: instance.processIdentifier).map { "\($0.number) L\($0.layer) \($0.frame)" }); ax \(managed().accessibilityWindows().map { "\(String(describing: $0.frame)) \($0.isMinimized)" })")
        for entry in entries() where orderLocator.isKnown(path: entry.exactPath) {
            if let window = try? await orderLocator.locate(path: entry.exactPath, in: managed()) {
                let folder = entry.exactPath.precomposedStringWithCanonicalMapping
                check("creation order: \(entry.displayName) is the right window",
                      document(window).precomposedStringWithCanonicalMapping.contains(folder + "/"), document(window))
                check("creation order: \(entry.displayName) reports minimized correctly",
                      orderLocator.isMinimized(path: entry.exactPath) == window.isMinimized)
            }
        }
        let orderHeights = managed().accessibilityWindows().compactMap(\.frame?.height)
        check("creation order: every height is back", orderHeights.allSatisfy { $0 == frame.height }, "\(orderHeights)")

        func closeWindow(_ window: AccessibilityWindow) async {
            if window.isMinimized { try? window.setMinimized(false); await settle(1) }
            let button = AccessibilityWindow.attribute(window.element, kAXCloseButtonAttribute)
            if let button, CFGetTypeID(button) == AXUIElementGetTypeID() {
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            }
            await settle(2)
        }
        func minimizedAgree(_ checking: VSCodeWindowLocator, _ name: String) async {
            for entry in entries() where checking.isKnown(path: entry.exactPath) {
                if let window = try? await checking.locate(path: entry.exactPath, in: managed()) {
                    let folder = entry.exactPath.precomposedStringWithCanonicalMapping
                    // Detaching takes the editor away, which leaves only the title to go by.
                    let title = (window as? AccessibilityWindow)?.title?.precomposedStringWithCanonicalMapping ?? ""
                    check("\(name): \(entry.displayName) is the right window",
                          document(window).isEmpty
                              ? title.contains(entry.displayName.precomposedStringWithCanonicalMapping)
                              : document(window).precomposedStringWithCanonicalMapping.contains(folder + "/"),
                          "\(document(window)) \(title)")
                    check("\(name): \(entry.displayName) reports minimized correctly",
                          checking.isMinimized(path: entry.exactPath) == window.isMinimized)
                }
            }
        }

        // Minimizing and restoring again and again: the state read for the panel has to
        // follow every time.
        var followMismatches: [String] = []
        for cycle in 0..<3 {
            for entry in entries() {
                guard let window = try? await orderLocator.locate(path: entry.exactPath, in: managed()) else { continue }
                let original = window.isMinimized
                for target in [!original, original] {
                    try? window.setMinimized(target)
                    await settle(1.2)
                    if orderLocator.isMinimized(path: entry.exactPath) != target {
                        followMismatches.append("\(cycle) \(entry.displayName) \(target)")
                    }
                }
            }
        }
        check("following: the state follows every minimize and restore", followMismatches.isEmpty, "\(followMismatches)")

        // A window opened while Switch is watching: known windows must stay right while
        // the new one is not saved yet, and the new one pairs after the first save.
        let gamma = projects.appendingPathComponent("gamma", isDirectory: true)
        try? fileManager.createDirectory(at: gamma, withIntermediateDirectories: true)
        try? "marker".write(to: gamma.appendingPathComponent("marker-gamma.txt"), atomically: true, encoding: .utf8)
        let knownBefore = entries().map(\.exactPath)
        await open([gamma.path, gamma.path + "/marker-gamma.txt"])
        await settle(3)
        check("new window: the windows known before stay known", knownBefore.allSatisfy { orderLocator.isKnown(path: $0) })
        await minimizedAgree(orderLocator, "new window, before a save")
        await flip(2)
        let gammaEntry = entries().first { $0.exactPath.hasSuffix("/gamma") }
        check("new window: it pairs after a save", gammaEntry.map { orderLocator.isKnown(path: $0.exactPath) } == true,
              "\(entries().map(\.displayName))")
        await minimizedAgree(orderLocator, "new window, after a save")
        if let gammaEntry, let window = try? await orderLocator.locate(path: gammaEntry.exactPath, in: managed()) as? AccessibilityWindow {
            // Minimizing it is the case the user reported: the label has to follow.
            try? window.setMinimized(true)
            await settle(1.5)
            check("new window: minimizing it shows", orderLocator.isMinimized(path: gammaEntry.exactPath))
            await closeWindow(window)
        }
        await flip(2)
        orderResolver.stop()

        // A detached editor is a window VS Code does not save, so the numbers cannot line up.
        // Keys are posted only while the throwaway VS Code is in front.
        let countBeforeDetach = managed().accessibilityWindows().count
        instance.activate()
        await settle(1.5)
        if instance.isActive {
            if let visible = managed().accessibilityWindows().first(where: { !$0.isMinimized }) { try? visible.raise() }
            await settle(0.5)
            let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 111, keyDown: down)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
            }
            IsolatedAppChecks.clearPostedModifiers()
            await settle(4)
        }
        let detached = managed().accessibilityWindows().count == countBeforeDetach + 1
        check("detached editor: it opened", detached, "\(countBeforeDetach) -> \(managed().accessibilityWindows().count)")
        if detached {
            let detachedLocator = VSCodeWindowLocator(opener: opener, applicationURL: { appURL })
            let detachedResolver = VSCodeWindowResolver(locator: detachedLocator, findApplication: { currentInstance() }, supportDirectory: { data })
            detachedResolver.start()
            await settle(2)
            await minimizedAgree(detachedLocator, "detached editor, before a save")
            checks.append(Check(name: "detached editor: attributes of every window", passed: true, detail: managed().accessibilityWindows().map { window -> String in
                var names: CFArray?
                AXUIElementCopyAttributeNames(window.element, &names)
                let list = (names as? [String] ?? []).sorted().joined(separator: ",")
                let children = (AccessibilityWindow.attribute(window.element, kAXChildrenAttribute) as? [AXUIElement])?.count ?? -1
                let minimum = AccessibilityWindow.attribute(window.element, "AXMinimumSize") != nil
                return "[\(window.title ?? "") doc=\(document(window).isEmpty ? "no" : "yes") children=\(children) min=\(minimum) \(String(describing: window.frame)) \(list)]"
            }.joined(separator: " ")))
            await flip(3)
            check("detached editor: every window pairs after a save", entries().allSatisfy { detachedLocator.isKnown(path: $0.exactPath) },
                  "\(entries().filter { detachedLocator.isKnown(path: $0.exactPath) }.count) of \(entries().count)")
            await minimizedAgree(detachedLocator, "detached editor, after a save")
            // Every window has exactly one row: one per saved path, and the rest below the line.
            let detachedRows = detachedResolver.windowsWithoutPath()
            check("detached editor: it is the one window listed without a path", detachedRows.count == 1,
                  "\(detachedRows.map { $0.title ?? "" })")
            check("detached editor: no window is listed twice, and none is missing",
                  entries().count + detachedRows.count == managed().accessibilityWindows().count,
                  "\(entries().count) paths, \(detachedRows.count) without, \(managed().accessibilityWindows().count) windows")
            detachedResolver.stop()
            // The detached one is the window no saved path owns.
            var owned: [AccessibilityWindow] = []
            for entry in entries() where detachedLocator.isKnown(path: entry.exactPath) {
                if let window = try? await detachedLocator.locate(path: entry.exactPath, in: managed()) as? AccessibilityWindow { owned.append(window) }
            }
            for window in managed().accessibilityWindows() where !owned.contains(where: { $0.isSame(as: window) }) {
                await closeWindow(window)
            }
            await flip(2)
            check("detached editor: it closed", managed().accessibilityWindows().count == countBeforeDetach, "\(managed().accessibilityWindows().count)")
        }
        // A window with no folder holds a place in the saved order, and has no path to pair.
        let countBeforeEmpty = managed().accessibilityWindows().count
        let emptyLocator = VSCodeWindowLocator(opener: opener, applicationURL: { appURL })
        let emptyResolver = VSCodeWindowResolver(locator: emptyLocator, findApplication: { currentInstance() }, supportDirectory: { data })
        emptyResolver.start()
        await settle(2)
        check("empty window: none is listed before it opens", emptyResolver.windowsWithoutPath().isEmpty,
              "\(emptyResolver.windowsWithoutPath().map { $0.title ?? "" })")
        await open(["--new-window"])
        await settle(4)
        check("empty window: it opened", managed().accessibilityWindows().count == countBeforeEmpty + 1,
              "\(countBeforeEmpty) -> \(managed().accessibilityWindows().count)")
        check("empty window: it is listed before VS Code saves", emptyResolver.windowsWithoutPath().count == 1,
              "\(emptyResolver.windowsWithoutPath().map { $0.title ?? "" })")
        await flip(2)
        let emptyRows = emptyResolver.windowsWithoutPath()
        check("empty window: it is listed after a save", emptyRows.count == 1, "\(emptyRows.map { $0.title ?? "" })")
        check("empty window: every path still pairs", entries().allSatisfy { emptyLocator.isKnown(path: $0.exactPath) },
              "\(entries().filter { emptyLocator.isKnown(path: $0.exactPath) }.count) of \(entries().count)")
        check("empty window: no window is listed twice, and none is missing",
              entries().count + emptyRows.count == managed().accessibilityWindows().count,
              "\(entries().count) paths, \(emptyRows.count) without, \(managed().accessibilityWindows().count) windows")
        if let empty = emptyRows.first {
            let switcher = WindowSwitcher(locateVSCodeWindow: { try await emptyLocator.locate(path: $0, in: $1) })
            let area = CGRect(x: 60, y: 80, width: 1000, height: 700)
            do {
                try await switcher.apply([.direct(empty)], in: managed(), columnsArea: area)
                check("empty window: choosing it brings it forward", instance.isActive && !empty.isMinimized)
                check("empty window: choosing it fills the area", empty.frame == area, "\(String(describing: empty.frame))")
                check("empty window: choosing it minimizes the others",
                      managed().accessibilityWindows().filter { !$0.isSame(as: empty) }.allSatisfy(\.isMinimized))
                try await switcher.apply([.vscode(path: entries()[0].exactPath)], in: managed(), columnsArea: area)
                check("empty window: choosing a path minimizes it", empty.isMinimized)
            } catch {
                check("empty window: choosing it", false, error.localizedDescription)
            }
            if empty.isMinimized { try? empty.setMinimized(false); await settle(1) }
            await closeWindow(empty)
            await flip(2)
            check("empty window: it closed and its row went",
                  managed().accessibilityWindows().count == countBeforeEmpty && emptyResolver.windowsWithoutPath().isEmpty,
                  "\(managed().accessibilityWindows().count) windows, \(emptyResolver.windowsWithoutPath().count) without")
        }
        emptyResolver.stop()
        // Later checks identify windows by their open file, so the detached one comes back.
        for (index, name) in names.enumerated() {
            let title = name.precomposedStringWithCanonicalMapping
            let window = managed().accessibilityWindows().first { $0.title?.precomposedStringWithCanonicalMapping.contains(title) == true }
            if let window, document(window).isEmpty { await openWindow(index) }
        }
        for window in managed().accessibilityWindows() { try? window.setFrame(frame) }
        for (index, window) in managed().accessibilityWindows().enumerated() where index > 0 { try? window.setMinimized(true) }
        await settle(3)

        resolver.start()
        await flip(4)
        await verifyPairs("separated windows", expected: names.count)
        let heights = managed().accessibilityWindows().compactMap(\.frame?.height)
        check("separation: every height is back", heights.allSatisfy { $0 == frame.height }, "\(heights)")

        // Every window minimized, with nothing paired: the command has to bring one back.
        let allHidden = VSCodeWindowLocator(opener: opener, applicationURL: { appURL })
        for window in managed().accessibilityWindows() { try? window.setMinimized(true) }
        await settle(3)
        if let first = entries().first {
            let windowsBefore = managed().accessibilityWindows().count
            do {
                let window = try await allHidden.locate(path: first.exactPath, in: managed())
                let folder = first.exactPath.precomposedStringWithCanonicalMapping
                check("all minimized: the command finds the right window", document(window).contains(folder + "/"), document(window))
            } catch {
                let app = AXUIElementCreateApplication(instance.processIdentifier)
                let focused = AccessibilityWindow.attribute(app, kAXFocusedWindowAttribute) != nil
                let main = AccessibilityWindow.attribute(app, kAXMainWindowAttribute) != nil
                let states = managed().accessibilityWindows().map { "\($0.isMinimized ? "min" : "VIS"):\(document($0).suffix(24))" }
                check("all minimized: the command finds the right window", false,
                      "\(error.localizedDescription) focusedAttr=\(focused) mainAttr=\(main) frontmost=\(instance.isActive) \(states)")
            }
            check("all minimized: no new window opened", managed().accessibilityWindows().count == windowsBefore)
            await settle(1)
        }

        // Selecting through the real switcher, with no command needed.
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }), let primary = NSScreen.screens.first else {
            fatalError("No screen")
        }
        let area = WindowLayout.accessibilityFrame(appKitFrame: screen.visibleFrame, primaryScreenHeight: primary.frame.height)
        let switcher = WindowSwitcher(locateVSCodeWindow: { try await locator.locate(path: $0, in: $1) })
        let list = entries()
        func select(_ chosen: [VSCodeWindowEntry], _ name: String) async {
            let before = managed().accessibilityWindows().count
            do {
                let start = Date()
                try await switcher.apply(chosen.map { .vscode(path: $0.exactPath) }, in: managed(), columnsArea: area)
                checks.append(Check(name: "\(name): ms", passed: true, detail: "\(Int(Date().timeIntervalSince(start) * 1000))"))
                check("\(name): completes", true)
            } catch {
                check("\(name): completes", false, error.localizedDescription)
            }
            await settle(3.5)
            let after = managed().accessibilityWindows()
            check("\(name): no new window opened", after.count == before, "\(before) -> \(after.count)")
            let columns = WindowLayout.columns(count: chosen.count, in: area)
            let visible = after.filter { !$0.isMinimized }
            check("\(name): only the chosen windows are visible", visible.count == chosen.count, "\(visible.count)")
            for (index, entry) in chosen.enumerated() {
                let folder = entry.exactPath.precomposedStringWithCanonicalMapping
                let match = visible.first { document($0).contains(folder + "/") }
                check("\(name): \(entry.displayName) is visible", match != nil, "visible: \(visible.map(document))")
                if let match, let actual = match.frame {
                    check("\(name): \(entry.displayName) has its column",
                          abs(actual.minX - columns[index].minX) <= 2 && abs(actual.width - columns[index].width) <= 2,
                          "\(actual) expected \(columns[index])")
                }
            }
        }
        if list.count >= 4 {
            await select([list[0]], "one known window")
            await select([list[1], list[2]], "two known windows")
            let japanese = list.first { $0.exactPath.precomposedStringWithCanonicalMapping.hasSuffix("\u{30B5}\u{30FC}\u{30D0}") }
            check("the Japanese folder is listed", japanese != nil, "\(list.map(\.displayName))")
            if let japanese {
                await select([japanese], "the Japanese folder")
                let bytes = Array(japanese.exactPath.utf8)
                let isComposed = japanese.exactPath.unicodeScalars.contains("\u{30D0}")
                checks.append(Check(name: "the Japanese folder: stored form", passed: true, detail: isComposed ? "NFC" : "NFD (\(bytes.count) bytes)"))
                // The command path, which is where the extra window once appeared.
                let fresh = VSCodeWindowLocator(opener: opener, applicationURL: { appURL })
                let before = managed().accessibilityWindows().count
                let target = list.first { $0.exactPath == japanese.exactPath }
                do {
                    let window = try await fresh.locate(path: target?.exactPath ?? "", in: managed())
                    check("the command reaches the Japanese window", document(window).precomposedStringWithCanonicalMapping.contains(japanese.exactPath.precomposedStringWithCanonicalMapping + "/"), document(window))
                } catch {
                    check("the command reaches the Japanese window", false, error.localizedDescription)
                }
                await settle(2)
                check("the command opens no new window", managed().accessibilityWindows().count == before, "\(before) -> \(managed().accessibilityWindows().count)")
            }
        } else {
            check("enough windows for the selection tests", false, "\(list.count)")
        }

        // Closing a window and opening the same folder again.
        let closingPath = folderPaths[0]
        let closingEntry = list.first { $0.exactPath.precomposedStringWithCanonicalMapping == closingPath }
        if let closingEntry, let window = try? await locator.locate(path: closingEntry.exactPath, in: managed()) as? AccessibilityWindow {
            let closeButton = AccessibilityWindow.attribute(window.element, kAXCloseButtonAttribute)
            if window.isMinimized { try? window.setMinimized(false); await settle(1) }
            if let closeButton, CFGetTypeID(closeButton) == AXUIElementGetTypeID() {
                AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
            }
            await settle(2)
            check("closing: the window reports it no longer exists", !window.exists)
            locator.forgetClosedWindows()
            check("closing: its path is forgotten", !locator.isKnown(path: closingEntry.exactPath))
            await openWindow(0)
            await settle(2)
            await flip(4)
            let reopened = entries().first { $0.exactPath.precomposedStringWithCanonicalMapping == closingPath }
            check("reopening: the path is listed again", reopened != nil)
            if let reopened {
                check("reopening: the path pairs with the new window", locator.isKnown(path: reopened.exactPath))
                if locator.isKnown(path: reopened.exactPath),
                   let found = try? await locator.locate(path: reopened.exactPath, in: managed()) {
                    check("reopening: it is the right window", document(found).contains(closingPath + "/"), document(found))
                }
            }
        } else {
            check("closing: has the window", false)
        }

        // Quitting VS Code and starting it again.
        instance.terminate()
        for _ in 0..<300 where !instance.isTerminated { await settle(0.1) }
        if !instance.isTerminated { instance.forceTerminate(); await settle(2) }
        check("quit: VS Code has quit", instance.isTerminated)
        resolver.reattach()
        await settle(1)
        check("quit: nothing is left paired to a window that is gone", {
            locator.forgetClosedWindows()
            return folderPaths.allSatisfy { !locator.isKnown(path: $0) } && entries().allSatisfy { !locator.isKnown(path: $0.exactPath) }
        }())
        await openWindow(0)
        await settle(5)
        if let relaunched = findInstance() {
            instance = relaunched
            resolver.reattach()
            await settle(2)
            let count = managed().accessibilityWindows().count
            await flip(4)
            let known = entries().filter { locator.isKnown(path: $0.exactPath) }.count
            check("relaunch: windows pair again", known == count && count > 0, "\(known) of \(count)")
            await verifyPairs("relaunch", expected: known)

            // A folder saved before a workspace: VS Code restores workspaces first, so the
            // saved list is out of order until the first save of the new run.
            let workspaceFile = projects.appendingPathComponent("shared.code-workspace").path
            try? "{\"folders\":[{\"path\":\"alpha\"}]}".write(toFile: workspaceFile, atomically: true, encoding: .utf8)
            await openWindow(1)
            await open([workspaceFile])
            await settle(3)
            await flip(2)
            resolver.stop()
            let countAtQuit = managed().accessibilityWindows().count
            for (index, window) in managed().accessibilityWindows().enumerated() where index > 0 { try? window.setMinimized(true) }
            await settle(3)
            instance.terminate()
            for _ in 0..<300 where !instance.isTerminated { await settle(0.1) }
            check("reorder: VS Code has quit", instance.isTerminated)
            await open([])
            await settle(8)
            if let restored = findInstance() {
                instance = restored
                let restoredList = entries()
                check("reorder: the saved list has a folder before the workspace",
                      restoredList.count >= 2 && (try? catalog.pathsInCreationOrder())?.last??.hasSuffix(".code-workspace") == true,
                      "\(String(describing: try? catalog.pathsInCreationOrder()))")
                let reorderLocator = VSCodeWindowLocator(opener: opener, applicationURL: { appURL })
                let reorderResolver = VSCodeWindowResolver(locator: reorderLocator, findApplication: { currentInstance() }, supportDirectory: { data })
                reorderResolver.start()
                await settle(3)
                func wrongPairs() async -> [String] {
                    var wrong: [String] = []
                    for entry in entries() where reorderLocator.isKnown(path: entry.exactPath) {
                        guard let window = try? await reorderLocator.locate(path: entry.exactPath, in: managed()) else { continue }
                        let title = (window as? AccessibilityWindow)?.title ?? ""
                        if !title.precomposedStringWithCanonicalMapping.contains(entry.displayName.precomposedStringWithCanonicalMapping) {
                            wrong.append("\(entry.displayName) <- \(title)")
                        }
                    }
                    return wrong
                }
                let restoredWindows = managed().accessibilityWindows()
                checks.append(Check(name: "reorder: windows restored, of those at quit", passed: true,
                                    detail: "\(restoredWindows.count) of \(countAtQuit), minimized \(restoredWindows.filter(\.isMinimized).count)"))
                let wrongBefore = await wrongPairs()
                check("reorder: before any save, no window pairs wrongly", wrongBefore.isEmpty, "\(wrongBefore)")
                check("reorder: before any save, no window is listed twice",
                      entries().count + reorderResolver.windowsWithoutPath().count <= managed().accessibilityWindows().count,
                      "\(entries().count) paths, \(reorderResolver.windowsWithoutPath().count) without, \(managed().accessibilityWindows().count) windows")
                checks.append(Check(name: "reorder: pairs before any save", passed: true,
                                    detail: "\(entries().filter { reorderLocator.isKnown(path: $0.exactPath) }.count) of \(entries().count)"))
                await flip(3)
                let wrongAfter = await wrongPairs()
                check("reorder: after a save, every window pairs", entries().allSatisfy { reorderLocator.isKnown(path: $0.exactPath) },
                      "\(entries().filter { reorderLocator.isKnown(path: $0.exactPath) }.count) of \(entries().count)")
                check("reorder: after a save, no window pairs wrongly", wrongAfter.isEmpty, "\(wrongAfter)")

                // The first thing after a relaunch, in the user's way: Command+M, no Switch.
                let firstLocator = VSCodeWindowLocator(opener: opener, applicationURL: { appURL })
                reorderResolver.stop()
                instance.terminate()
                for _ in 0..<300 where !instance.isTerminated { await settle(0.1) }
                await open([])
                await settle(8)
                if let again = findInstance() {
                    instance = again
                    let firstResolver = VSCodeWindowResolver(locator: firstLocator, findApplication: { currentInstance() }, supportDirectory: { data })
                    firstResolver.start()
                    await settle(2)
                    instance.activate()
                    await settle(1.5)
                    if instance.isActive {
                        for down in [true, false] {
                            let event = CGEvent(keyboardEventSource: nil, virtualKey: 46, keyDown: down)
                            event?.flags = .maskCommand
                            event?.post(tap: .cghidEventTap)
                        }
                        IsolatedAppChecks.clearPostedModifiers()
                        await settle(3)
                        let minimizedWindows = managed().accessibilityWindows().filter(\.isMinimized)
                        check("first minimize: a window is minimized", minimizedWindows.count == 1, "\(minimizedWindows.count)")
                        initial?.activate()
                        await settle(2)
                        let shown = entries().filter { firstLocator.isMinimized(path: $0.exactPath) }
                        check("first minimize: the panel can tell which, without Switch doing anything", shown.count == minimizedWindows.count,
                              "\(shown.map(\.displayName)) known \(entries().filter { firstLocator.isKnown(path: $0.exactPath) }.count) of \(entries().count)")
                        if let window = shown.first.flatMap({ entry in managed().accessibilityWindows().first { $0.title?.precomposedStringWithCanonicalMapping.contains(entry.displayName.precomposedStringWithCanonicalMapping) == true && $0.isMinimized } }) {
                            check("first minimize: it is the right window", window.isMinimized)
                        } else if !shown.isEmpty {
                            check("first minimize: it is the right window", false, "\(shown.map(\.displayName))")
                        }
                    } else {
                        check("first minimize: the throwaway VS Code is in front", false)
                    }
                    // A real question about unsaved work: an edited file, with hot exit off.
                    firstResolver.stop()
                    let dirtyFile = folderPaths[0] + "/marker-\(names[0]).txt"
                    await open([folderPaths[0], dirtyFile])
                    await settle(3)
                    let settingsPath = data.appendingPathComponent("User/settings.json").path
                    try? "{\"files.hotExit\":\"off\",\"telemetry.telemetryLevel\":\"off\",\"update.mode\":\"none\",\"security.workspace.trust.enabled\":false}"
                        .write(toFile: settingsPath, atomically: true, encoding: .utf8)
                    await settle(2)
                    instance.activate()
                    await settle(1.5)
                    if instance.isActive {
                        func sheetTexts() -> [String] {
                            let app = AXUIElementCreateApplication(instance.processIdentifier)
                            func walk(_ element: AXUIElement) -> [AXUIElement] {
                                let children = AccessibilityWindow.attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
                                return children + children.flatMap(walk)
                            }
                            let windows = AccessibilityWindow.attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
                            let sheets = windows.flatMap { (AccessibilityWindow.attribute($0, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
                                .filter { (AccessibilityWindow.attribute($0, kAXRoleAttribute) as? String) == "AXSheet" }
                            return sheets.flatMap(walk).compactMap {
                                (AccessibilityWindow.attribute($0, kAXValueAttribute) as? String) ?? (AccessibilityWindow.attribute($0, kAXTitleAttribute) as? String)
                            }
                        }
                        checks.append(Check(name: "question: a sheet already there", passed: true, detail: "\(sheetTexts())"))
                        if !sheetTexts().isEmpty {
                            for down in [true, false] {
                                CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
                            }
                            await settle(1.5)
                        }
                        for down in [true, false] {
                            CGEvent(keyboardEventSource: nil, virtualKey: 7, keyDown: down)?.post(tap: .cghidEventTap)
                        }
                        await settle(1.5)
                        let application = managed()
                        let questionsBefore = application.questionCount
                        func describeWindows() -> String {
                            let app = AXUIElementCreateApplication(instance.processIdentifier)
                            let all = AccessibilityWindow.attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
                            return all.map { window in
                                let children = AccessibilityWindow.attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
                                let roles = children.compactMap { AccessibilityWindow.attribute($0, kAXRoleAttribute) as? String }
                                return "[\(AccessibilityWindow.attribute(window, kAXTitleAttribute) as? String ?? "") \(AccessibilityWindow.attribute(window, kAXSubroleAttribute) as? String ?? "") \(roles)]"
                            }.joined(separator: " ")
                        }
                        checks.append(Check(name: "question: shown before quitting", passed: true, detail: "\(questionsBefore) \(describeWindows())"))
                        check("question: the request to quit is sent", application.terminate())
                        var asked = false
                        for _ in 0..<60 where !asked { await settle(0.1); asked = application.questionCount > questionsBefore }
                        check("question: the panel's check sees VS Code asking", asked)
                        check("question: VS Code is still running", !instance.isTerminated)
                        checks.append(Check(name: "question: shown after the request", passed: true, detail: "\(application.questionCount) \(describeWindows()) \(sheetTexts())"))
                    } else {
                        check("question: the throwaway VS Code is in front", false)
                    }
                    instance.forceTerminate()
                    for _ in 0..<100 where !instance.isTerminated { await settle(0.1) }
                } else {
                    check("first minimize: VS Code is running again", false)
                }
            } else {
                check("reorder: the throwaway VS Code is running again", false)
            }
            instance.terminate()
            for _ in 0..<100 where !instance.isTerminated { await settle(0.1) }
        } else {
            check("relaunch: the throwaway VS Code is running again", false)
        }
        finish(outputPath)
    }

    static func commandLine(of pid: pid_t) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "command=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private static func finish(_ outputPath: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(checks).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        } catch {
            fatalError("Cannot write \(outputPath): \(error)")
        }
    }
}
#endif
