#if DEBUG
import AppKit
import ApplicationServices

/// Debug-only test of the real Accessibility path. XCTest cannot do this, because
/// the permission belongs to the signed app. It starts its own fixture applications
/// and moves only their windows.
///
///   open -n -W .build/Switch.app --args --self-test /path/to/output.json
@MainActor
enum RealWindowSelfTest {
    static let argument = "--self-test"
    static let fixtureArgument = "--fixture-windows"
    static let fixedFixtureArgument = "--fixture-fixed"

    static func outputPath(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func fixtureWindowCount(arguments: [String]) -> Int? {
        guard let index = arguments.firstIndex(of: fixtureArgument), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }

    static let askingFixtureArgument = "--fixture-asks"
    private static var fixtureWindows: [NSWindow] = []

    /// A fixture that answers a request to quit as an application with unsaved work does.
    static func askBeforeQuitting() -> NSApplication.TerminateReply {
        guard let index = CommandLine.arguments.firstIndex(of: askingFixtureArgument), index + 1 < CommandLine.arguments.count else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Save changes?"
        if CommandLine.arguments[index + 1] == "sheet", let window = fixtureWindows.first {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            DispatchQueue.main.async { alert.runModal() }
        }
        return .terminateCancel
    }

    static func showFixture(windowCount: Int) {
        let fixed = CommandLine.arguments.contains(fixedFixtureArgument)
        NSApp.setActivationPolicy(.regular)
        for index in 0..<windowCount {
            var style: NSWindow.StyleMask = [.titled, .miniaturizable, .closable]
            if !fixed { style.insert(.resizable) }
            let window = NSWindow(contentRect: NSRect(x: 80 + index * 50, y: 120 + index * 40, width: 420, height: 300),
                                  styleMask: style, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Switch test \(index)"
            window.makeKeyAndOrderFront(nil)
            fixtureWindows.append(window)
        }
    }

    struct Check: Encodable {
        let name: String
        let passed: Bool
        let detail: String
    }

    struct Report: Encodable {
        let passed: Int
        let failed: [Check]
        let notTested: [String]
        let checks: [Check]
    }

    private static var checks: [Check] = []
    private static var notTested: [String] = []

    private static func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
        checks.append(Check(name: name, passed: passed, detail: passed ? "" : detail()))
    }

    private static func launchFixture(windows: Int, fixed: Bool = false) async -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = [fixtureArgument, String(windows)] + (fixed ? [fixedFixtureArgument] : [])
        guard let application = try? await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) else {
            fatalError("Cannot start a fixture")
        }
        return application
    }

    private static func settle(_ seconds: Double = 0.4) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func windows(of application: NSRunningApplication, count: Int) async -> [AccessibilityWindow] {
        let managed = AccessibilityApplication(application: application)
        for _ in 0..<100 {
            let listed = managed.accessibilityWindows()
            if listed.count >= count { return listed }
            await settle(0.05)
        }
        fatalError("Fixture windows did not appear")
    }

    private static func near(_ a: CGRect?, _ b: CGRect) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    /// Windows from front to back, by owning process, as the window server orders them.
    private static func frontToBackOwners() -> [pid_t] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { $0[kCGWindowOwnerPID as String] as? pid_t }
    }

    /// Drives the real panel with real input events, so it moves the pointer for a
    /// moment. It clicks only the status icon and the panel, and puts the pointer back.
    private static func runPanelChecks(windows: [AccessibilityWindow], application: AccessibilityApplication, primaryHeight: CGFloat) async {
        var applied: [[String]] = []
        let panel = WindowPanelController(onApply: { _, chosen in applied.append(chosen.map(\.title)) },
                                          onRequestPermission: {}, onQuit: {})
        let listed = ListedApplication(
            name: "Fixture", icon: nil,
            windows: ["a", "b", "c"].map {
                ListedWindow(title: $0, toolTip: nil, isMinimized: false, selection: .direct(windows[0]))
            },
            problem: nil, application: application)
        let bar = MenuBarController(onClick: { [weak panel] anchor in
            guard let panel else { return }
            if panel.isVisible {
                panel.close()
                return
            }
            guard !panel.wasJustClosed else { return }
            panel.show(applications: [listed], hasPermission: true, frontmostName: "Fixture", below: anchor)
        })
        defer {
            panel.close()
            bar.invalidate()
        }
        let pointerBefore = NSEvent.mouseLocation
        func flip(_ point: NSPoint) -> CGPoint { CGPoint(x: point.x, y: primaryHeight - point.y) }
        func post(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags = []) {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        func click(_ point: NSPoint, flags: CGEventFlags = []) async {
            let target = flip(point)
            post(.mouseMoved, at: target, flags: flags)
            await settle(0.1)
            post(.leftMouseDown, at: target, flags: flags)
            await settle(0.06)
            post(.leftMouseUp, at: target, flags: flags)
            await settle(0.3)
        }
        func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        guard let button = bar.buttonForTesting, let buttonWindow = button.window else {
            check("panel: status button exists", false)
            return
        }
        await settle(0.3)
        let icon = NSPoint(x: buttonWindow.frame.midX, y: buttonWindow.frame.midY)

        let anchor = NSRect(x: icon.x - 15, y: buttonWindow.frame.minY, width: 30, height: buttonWindow.frame.height)
        func open() {
            panel.show(applications: [listed], hasPermission: true, frontmostName: "Fixture", below: anchor)
        }

        // A second status item can land where it cannot be clicked, such as behind the
        // camera housing. That says nothing about the app's own icon, so it is not a pass.
        if buttonWindow.occlusionState.contains(.visible) {
            await click(icon)
            check("panel: clicking the icon opens it", panel.isVisible)
            await click(icon)
            check("panel: clicking the icon again closes it", !panel.isVisible)
            await settle(0.6)
        } else {
            notTested.append("clicking the status icon: the test's own item is hidden at \(buttonWindow.frame)")
        }
        panel.close()

        open()
        await settle(0.2)
        key(53, down: true)
        key(53, down: false)
        await settle(0.3)
        check("panel: Escape closes it", !panel.isVisible)

        await settle(0.6)
        open()
        await settle(0.2)
        await click(panel.windowRowCenterForTesting(row: 1))
        check("panel: a plain click applies that window", applied.last == ["b"], "\(applied) visible \(panel.isVisible)")
        check("panel: a plain click closes it", !panel.isVisible)

        await settle(0.6)
        open()
        await settle(0.2)
        let count = applied.count
        let rowC = panel.windowRowCenterForTesting(row: 2), rowA = panel.windowRowCenterForTesting(row: 0)
        key(56, down: true, flags: .maskShift)
        await settle(0.1)
        await click(rowC, flags: .maskShift)
        await click(rowA, flags: .maskShift)
        check("panel: Shift+click applies nothing yet", applied.count == count, "\(applied)")
        check("panel: Shift+click keeps it open", panel.isVisible)
        check("panel: Shift+click records the order", panel.selection.rows == [2, 0], "\(panel.selection.rows)")
        key(56, down: false)
        await settle(0.4)
        check("panel: releasing Shift applies in click order", applied.last == ["c", "a"], "\(applied)")
        check("panel: releasing Shift closes it", !panel.isVisible)

        await settle(0.6)
        open()
        await settle(0.2)
        let rowB = panel.windowRowCenterForTesting(row: 1)
        let afterTwo = applied.count
        key(56, down: true, flags: .maskShift)
        await settle(0.1)
        await click(rowB, flags: .maskShift)
        key(53, down: true, flags: .maskShift)
        key(53, down: false, flags: .maskShift)
        await settle(0.3)
        key(56, down: false)
        await settle(0.3)
        check("panel: Escape during Shift+click cancels", !panel.isVisible && applied.count == afterTwo, "\(applied) visible \(panel.isVisible)")

        // Clicking outside closes it. The click lands on this test's own fixture window,
        // brought in front first, so that nothing of the user's receives it.
        await settle(0.6)
        if let target = windows.first, let frame = target.frame {
            try? target.raise()
            NSRunningApplication(processIdentifier: { var pid: pid_t = 0; AXUIElementGetPid(target.element, &pid); return pid }())?.activate()
            await settle(0.8)
            open()
            await settle(0.3)
            let appliedBefore = applied.count
            let area = panel.panelFrameForTesting
            // The window's lower part, away from the panel, which hangs from the menu bar.
            let candidates = [CGPoint(x: frame.midX, y: frame.maxY - 20), CGPoint(x: frame.minX + 20, y: frame.maxY - 20)]
            let inPanel: (CGPoint) -> Bool = { point in
                let appKit = NSPoint(x: point.x, y: primaryHeight - point.y)
                return area.contains(appKit)
            }
            if let point = candidates.first(where: { !inPanel($0) }) {
                let topWindow = frontToBackOwners().first
                var pid: pid_t = 0
                AXUIElementGetPid(target.element, &pid)
                if topWindow == pid {
                    await click(NSPoint(x: point.x, y: primaryHeight - point.y))
                    check("panel: clicking outside closes it", !panel.isVisible)
                    check("panel: clicking outside applies nothing", applied.count == appliedBefore, "\(applied)")
                } else {
                    notTested.append("clicking outside the panel: the fixture window was not on top")
                }
            } else {
                notTested.append("clicking outside the panel: the fixture window was under the panel")
            }
        }

        CGWarpMouseCursorPosition(flip(pointerBefore))
    }

    static func run(outputPath: String) async {
        guard AXIsProcessTrusted() else { fatalError("Switch has no Accessibility permission") }
        let initial = NSWorkspace.shared.frontmostApplication
        let other = await launchFixture(windows: 2)
        await settle(1)
        let main = await launchFixture(windows: 4)
        await settle(1)
        let fixed = await launchFixture(windows: 2, fixed: true)
        await settle(1)
        defer {
            for application in [main, other, fixed] { application.forceTerminate() }
            initial?.activate()
        }

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
              let primary = NSScreen.screens.first else {
            fatalError("No screen")
        }
        let area = WindowLayout.accessibilityFrame(appKitFrame: screen.visibleFrame, primaryScreenHeight: primary.frame.height)
        let switcher = WindowSwitcher(locateVSCodeWindow: { _, _ in fatalError("No VS Code in this test") })
        let application = AccessibilityApplication(application: main)
        let all = await windows(of: main, count: 4)
        let others = await windows(of: other, count: 2)
        let otherFrames = others.map(\.frame)

        func otherUntouched(_ name: String) {
            check("\(name): other application's windows keep their frames",
                  zip(others, otherFrames).allSatisfy { $0.frame == $1 })
            check("\(name): other application's windows stay unminimized", others.allSatisfy { !$0.isMinimized })
        }
        func apply(_ chosen: [AccessibilityWindow], _ name: String) async {
            do {
                try await switcher.apply(chosen.map { .direct($0) }, in: application, columnsArea: area)
                check("\(name): completes without error", true)
            } catch {
                check("\(name): completes without error", false, error.localizedDescription)
            }
            await settle(2.2)
        }
        func verify(_ chosen: [AccessibilityWindow], _ name: String) {
            let frames = WindowLayout.columns(count: chosen.count, in: area)
            for (index, window) in chosen.enumerated() {
                check("\(name): window \(index) has its column", near(window.frame, frames[index]),
                      "\(String(describing: window.frame)) expected \(frames[index])")
                check("\(name): window \(index) is not minimized", !window.isMinimized)
            }
            for window in all where !chosen.contains(where: { $0.isSame(as: window) }) {
                check("\(name): unchosen window is minimized", window.isMinimized)
            }
            check("\(name): application is frontmost", NSWorkspace.shared.frontmostApplication == main)
            // Regression: the second window stayed behind other applications.
            let order = frontToBackOwners()
            let firstOther = order.firstIndex(of: other.processIdentifier) ?? Int.max
            let chosenInFront = order.prefix(while: { $0 == main.processIdentifier }).count
            check("\(name): every chosen window is above the other application",
                  chosenInFront >= chosen.count && chosenInFront <= firstOther,
                  "front run \(chosenInFront) of \(chosen.count), other at \(firstOther); main \(main.processIdentifier) other \(other.processIdentifier) fixed \(fixed.processIdentifier); top " + order.prefix(6).map { pid in
                      "\(pid):\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?")"
                  }.joined(separator: ","))
            let mainAttribute = AccessibilityWindow.attribute(chosen[0].element, kAXMainAttribute) as? Bool
            check("\(name): first chosen window is the main window", mainAttribute == true)
            otherUntouched(name)
        }

        let timed = Date()
        try? await switcher.apply([.direct(all[0])], in: application, columnsArea: area)
        let firstApplied = Date().timeIntervalSince(timed)
        checks.append(Check(name: "first selection: apply returned in ms", passed: true, detail: "\(Int(firstApplied * 1000))"))
        // How long the first selection takes to reach the top, and whether it ever does.
        let firstStart = Date()
        var firstOrders: [String] = []
        while Date().timeIntervalSince(firstStart) < 4 {
            let top = frontToBackOwners().first ?? 0
            firstOrders.append("\(Int(Date().timeIntervalSince(firstStart) * 1000)):\(NSRunningApplication(processIdentifier: top)?.localizedName ?? "?")")
            if top == main.processIdentifier { break }
            await settle(0.02)
        }
        checks.append(Check(name: "first selection: top over time", passed: true,
                            detail: firstOrders.joined(separator: " ") + " frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")"))
        await settle(2)
        verify([all[0]], "one window")
        // Regression: raising right after restoring failed with -25204 in Chrome.
        await apply([all[1], all[2]], "two minimized windows")
        verify([all[1], all[2]], "two minimized windows")
        await apply([all[3], all[0], all[1]], "three windows in click order")
        verify([all[3], all[0], all[1]], "three windows in click order")
        await apply([all[3], all[0], all[1]], "the same selection again")
        verify([all[3], all[0], all[1]], "the same selection again")
        await apply(all, "all four windows")
        verify(all, "all four windows")

        // Rapid selections that the panel would queue, run in sequence.
        await apply([all[2]], "after many switches")
        verify([all[2]], "after many switches")

        // The real situation: another application is active when the selection runs.
        if let initial {
            var waits: [Int] = []
            var failures = 0
            for round in 0..<8 {
                initial.activate()
                await settle(0.7)
                let wasFront = NSWorkspace.shared.frontmostApplication == initial
                let chosen = [all[round % 2]]
                do {
                    try await switcher.apply(chosen.map { .direct($0) }, in: application, columnsArea: area)
                } catch {
                    check("from another application: round \(round) completes", false, error.localizedDescription)
                }
                let start = Date()
                var reached = false
                while Date().timeIntervalSince(start) < 3 {
                    if frontToBackOwners().first == main.processIdentifier { reached = true; break }
                    await settle(0.02)
                }
                if reached {
                    waits.append(Int(Date().timeIntervalSince(start) * 1000))
                } else {
                    failures += 1
                }
                check("from another application: round \(round) started with it active", wasFront)
            }
            check("from another application: chosen window reaches the top", failures == 0, "\(failures) of 8 did not within 3 s")
            checks.append(Check(name: "from another application: wait in ms", passed: true, detail: "\(waits)"))
        }

        // An application whose windows have never been activated by Switch.
        if let initial {
            var results: [String] = []
            var failures = 0
            for round in 0..<6 {
                let fresh = await launchFixture(windows: 2)
                await settle(0.8)
                initial.activate()
                await settle(0.7)
                let freshWindows = await windows(of: fresh, count: 2)
                let managed = AccessibilityApplication(application: fresh)
                try? await switcher.apply([.direct(freshWindows[round % 2])], in: managed, columnsArea: area)
                let start = Date()
                var reached = false
                while Date().timeIntervalSince(start) < 3 {
                    if frontToBackOwners().first == fresh.processIdentifier { reached = true; break }
                    await settle(0.02)
                }
                let top = frontToBackOwners().first.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "?"
                results.append("\(reached ? "ok" : "NO") \(Int(Date().timeIntervalSince(start) * 1000))ms front=\(NSWorkspace.shared.frontmostApplication == fresh) top=\(top)")
                if !reached { failures += 1 }
                fresh.forceTerminate()
                await settle(0.3)
            }
            check("fresh application: reaches the top", failures == 0, "\(failures) of 6")
            checks.append(Check(name: "fresh application: detail", passed: true, detail: results.joined(separator: " | ")))
        }

        // Selections in quick succession, with animations still running. Each runs to
        // completion before the next, as the app delegate queues them.
        for round in 0..<8 {
            try? await switcher.apply([.direct(all[round % 2])], in: application, columnsArea: area)
        }
        await settle(3)
        check("rapid: the last chosen window is not minimized", !all[1].isMinimized, "minimized after the last selection")
        check("rapid: the previous window is minimized", all[0].isMinimized, "visible after the last selection")
        for pair in [[0, 1], [1, 2], [2, 3], [3, 0]] {
            try? await switcher.apply(pair.map { .direct(all[$0]) }, in: application, columnsArea: area)
        }
        await settle(3)
        let lastPair = [all[3], all[0]]
        check("rapid pairs: both last chosen windows are visible", lastPair.allSatisfy { !$0.isMinimized })
        check("rapid pairs: the others are minimized", [all[1], all[2]].allSatisfy(\.isMinimized))
        let lastColumns = WindowLayout.columns(count: 2, in: area)
        check("rapid pairs: columns are in place", near(all[3].frame, lastColumns[0]) && near(all[0].frame, lastColumns[1]),
              "\(String(describing: all[3].frame)) \(String(describing: all[0].frame))")

        // A full screen window.
        let fullScreenApp = await launchFixture(windows: 2)
        await settle(1)
        let fullScreenWindows = await windows(of: fullScreenApp, count: 2)
        let fullScreenManaged = AccessibilityApplication(application: fullScreenApp)
        let target = fullScreenWindows[1]
        AXUIElementSetAttributeValue(target.element, "AXFullScreen" as CFString, kCFBooleanTrue)
        await settle(2)
        check("full screen: the window reports full screen", target.isFullScreen)
        do {
            try await switcher.apply([.direct(target)], in: fullScreenManaged, columnsArea: area)
            check("full screen: selecting it is not an error", true)
        } catch {
            check("full screen: selecting it is not an error", false, error.localizedDescription)
        }
        await settle(1)
        check("full screen: it stays full screen", target.isFullScreen)
        AXUIElementSetAttributeValue(target.element, "AXFullScreen" as CFString, kCFBooleanFalse)
        await settle(2)
        fullScreenApp.forceTerminate()
        await settle(0.5)

        // A hung application must not hold up what is shown, and must keep its rows: it may
        // have windows, and not being able to say so is not the same as having none.
        let hung = await launchFixture(windows: 2)
        await settle(1)
        let hungIdentifier = hung.bundleIdentifier ?? ""
        var answeredBefore: [ListedApplication] = []
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WindowListing.load { applications in
                answeredBefore = applications
                continuation.resume()
            }
        }
        kill(hung.processIdentifier, SIGSTOP)
        let listStart = Date()
        var listedApplications: [ListedApplication] = []
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var shown = false
            let show: @MainActor ([ListedApplication]) -> Void = { applications in
                guard !shown else { return }
                shown = true
                listedApplications = applications
                continuation.resume()
            }
            WindowListing.load(previous: answeredBefore, partial: show, completion: show)
        }
        let listMs = Int(Date().timeIntervalSince(listStart) * 1000)
        kill(hung.processIdentifier, SIGCONT)
        hung.forceTerminate()
        check("hung application: the list is shown quickly", listMs < 1000, "\(listMs) ms")
        check("hung application: other applications are still listed", listedApplications.count >= 2, "\(listedApplications.count)")
        check("hung application: it keeps its rows", listedApplications.first { $0.identifier == hungIdentifier }?.windows.isEmpty == false,
              "\(listedApplications.map(\.identifier))")
        checks.append(Check(name: "hung application: list ms", passed: true, detail: "\(listMs)"))

        // Reading the list many times must not grow without bound.
        func residentKilobytes() -> Int {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-o", "rss=", "-p", String(ProcessInfo.processInfo.processIdentifier)]
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            process.waitUntilExit()
            return Int(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        func readList() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                WindowListing.load { _ in continuation.resume() }
            }
        }
        for _ in 0..<50 { await readList() }
        let residentBefore = residentKilobytes()
        for _ in 0..<300 { await readList() }
        let residentAfter = residentKilobytes()
        check("memory: 300 readings do not grow it much", residentAfter - residentBefore < 20_000, "\(residentBefore) -> \(residentAfter) KB")
        checks.append(Check(name: "memory: KB before and after", passed: true, detail: "\(residentBefore) -> \(residentAfter)"))

        // Separation on a minimized window.
        if let hidden = all.first(where: \.isMinimized), let original = hidden.frame {
            var changed = original
            changed.size.height -= 1
            try? hidden.setFrame(changed)
            await settle()
            check("separation: a minimized window takes the change", near(hidden.frame, changed), String(describing: hidden.frame))
            check("separation: the window stays minimized", hidden.isMinimized)
            try? hidden.setFrame(original)
            await settle()
            check("separation: the frame comes back", near(hidden.frame, original), String(describing: hidden.frame))
            check("separation: the window is still minimized", hidden.isMinimized)
        } else {
            check("separation: has a minimized window", false)
        }

        // A window that cannot be resized.
        let fixedManaged = AccessibilityApplication(application: fixed)
        let fixedWindows = await windows(of: fixed, count: 2)
        let frameBefore = fixedWindows[1].frame
        do {
            try await switcher.apply([.direct(fixedWindows[0]), .direct(fixedWindows[1])], in: fixedManaged, columnsArea: area)
            check("fixed size: reported or arranged", near(fixedWindows[0].frame, WindowLayout.columns(count: 2, in: area)[0]),
                  "no error, and the window did not take the frame: \(String(describing: fixedWindows[0].frame))")
        } catch {
            check("fixed size: reported or arranged", true)
            check("fixed size: nothing minimized after the failure", fixedWindows.allSatisfy { !$0.isMinimized })
        }
        _ = frameBefore

        // A closed window.
        let closing = all[2]
        check("closed: exists before closing", closing.exists)
        let closeButton = AccessibilityWindow.attribute(closing.element, kAXCloseButtonAttribute)
        if let closeButton, CFGetTypeID(closeButton) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
            await settle()
            check("closed: reports that it no longer exists", !closing.exists)
            do {
                try closing.raise()
                check("closed: raising it is an error", false)
            } catch {
                check("closed: raising it is an error", true)
            }
        } else {
            check("closed: has a close button", false)
        }

        await runPanelChecks(windows: others, application: AccessibilityApplication(application: other), primaryHeight: primary.frame.height)

        if NSScreen.screens.count < 2 { notTested.append("a second display: only one is connected") }
        let report = Report(passed: checks.filter(\.passed).count, failed: checks.filter { !$0.passed }, notTested: notTested, checks: checks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(report).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        } catch {
            fatalError("Cannot write \(outputPath): \(error)")
        }
    }
}
#endif
