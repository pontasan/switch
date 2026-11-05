#if DEBUG
import AppKit
import ApplicationServices

/// Debug-only checks against real applications without touching the user's windows:
/// the running Switch's own icon, and an instance of Chrome on a throwaway profile.
///
///   open -n -W .build/Switch.app --args --icon-check out.json
///   open -n -W .build/Switch.app --args --chrome-check out.json <pid>
///   open -n -W .build/Switch.app --args --quit-key-check out.json
@MainActor
enum IsolatedAppChecks {
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

    static func argument(_ flag: String, arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func write(_ outputPath: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(checks).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        } catch {
            fatalError("Cannot write \(outputPath): \(error)")
        }
    }

    // MARK: VS Code's state

    /// Read-only: what Accessibility and the saved state say right now, and which of
    /// them the bounds comparison would pair if the saved state could be trusted.
    static func writeVSCodeState(outputPath: String) {
        struct Saved: Encodable { let path: String; let bounds: [Int]? }
        struct Live: Encodable { let title: String; let number: Int?; let frame: [Int]?; let minimized: Bool }
        struct Server: Encodable { let id: Int; let frame: [Int]; let layer: Int; let onScreen: Bool }
        struct State: Encodable { let saved: [Saved]; let live: [Live]; let server: [Server] }
        func ints(_ rect: CGRect?) -> [Int]? {
            rect.map { [$0.minX, $0.minY, $0.width, $0.height].map { Int($0.rounded()) } }
        }
        guard AXIsProcessTrusted(),
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: VSCodeWindowCatalog.applicationBundleIdentifier).first,
              let support = try? VSCodeWindowCatalog.userSupportDirectory(),
              let entries = try? VSCodeWindowCatalog(supportDirectory: support).openWindows() else {
            fatalError("VS Code's state cannot be read")
        }
        let windows = AccessibilityApplication(application: running).accessibilityWindows()
        let state = State(
            saved: entries.map { entry in
                Saved(path: entry.exactPath, bounds: ints(entry.bounds))
            },
            live: windows.map { window in
                Live(title: window.title ?? "", number: window.number, frame: ints(window.frame), minimized: window.isMinimized)
            },
            server: ((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []).compactMap { info in
                guard (info[kCGWindowOwnerPID as String] as? pid_t) == running.processIdentifier,
                      let id = info[kCGWindowNumber as String] as? Int,
                      let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                      let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"] else { return nil }
                return Server(id: id, frame: ints(CGRect(x: x, y: y, width: width, height: height)) ?? [],
                              layer: info[kCGWindowLayer as String] as? Int ?? -1,
                              onScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        do {
            try encoder.encode(state).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        } catch {
            fatalError("Cannot write \(outputPath): \(error)")
        }
    }

    // MARK: The switching keys

    /// The application under test: three windows, and how it lists and reaches them.
    struct ShortcutTarget {
        let application: NSRunningApplication
        let rows: @MainActor () -> [ListedWindow]
        let number: @MainActor (ListedWindow) -> Int?
        let locate: (String, ManagedApplication) async throws -> ManagedWindow
    }

    /// `--shortcut-check out.json` uses a fixture, and adding `--bundle-identifier` and
    /// `--profile` uses an instance started on that throwaway profile instead.
    static func runShortcutCheck(outputPath: String, bundleIdentifier: String?, profile: String?) async {
        guard AXIsProcessTrusted() else { fatalError("No Accessibility permission") }
        let initial = NSWorkspace.shared.frontmostApplication
        defer { initial?.activate() }
        guard let bundleIdentifier, let profile else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.activates = true
            configuration.arguments = [RealWindowSelfTest.fixtureArgument, "3"]
            guard let fixture = try? await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) else {
                fatalError("Cannot start a fixture")
            }
            defer { fixture.forceTerminate() }
            await runShortcutCheck(outputPath: outputPath, target: directTarget(fixture))
            return
        }
        guard let instance = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier && IsolatedVSCodeCheck.commandLine(of: $0.processIdentifier).contains(profile)
        }) else { fatalError("The instance on the throwaway profile is not running") }
        guard bundleIdentifier == VSCodeWindowCatalog.applicationBundleIdentifier else {
            await runShortcutCheck(outputPath: outputPath, target: directTarget(instance))
            return
        }
        // Paired as the app itself does, from this instance's own saved state.
        let data = URL(fileURLWithPath: profile, isDirectory: true)
        let opener = VSCodeCLIWindowOpener(extraArguments: ["--user-data-dir", data.path])
        let locator = VSCodeWindowLocator(opener: opener, applicationURL: { instance.bundleURL ?? URL(fileURLWithPath: "/Applications/Visual Studio Code.app") })
        let resolver = VSCodeWindowResolver(locator: locator, findApplication: { instance }, supportDirectory: { data })
        resolver.start()
        let catalog = VSCodeWindowCatalog(supportDirectory: data)
        func entries() -> [VSCodeWindowEntry] { (try? catalog.openWindows()) ?? [] }
        // VS Code saves its windows when it loses focus.
        for _ in 0..<8 where entries().count != 3 || entries().contains(where: { !locator.isKnown(path: $0.exactPath) }) {
            instance.activate()
            await settle(1)
            initial?.activate()
            await settle(1.5)
            resolver.attachIfNeeded()
        }
        check("all 3 VS Code windows are paired by path", entries().count == 3 && entries().allSatisfy { locator.isKnown(path: $0.exactPath) },
              "\(entries().count) saved")
        let managed = AccessibilityApplication(application: instance)
        await runShortcutCheck(outputPath: outputPath, target: ShortcutTarget(
            application: instance,
            rows: {
                let list = entries()
                let reachable = Set(managed.accessibilityWindows().compactMap(\.number))
                return zip(list, VSCodeWindowCatalog.displayTitles(for: list)).map { entry, title in
                    let number = (locator.knownWindows[entry.exactPath] as? AccessibilityWindow)?.number
                    return ListedWindow(title: title, toolTip: entry.target.path,
                                        isMinimized: locator.knownWindows[entry.exactPath]?.isMinimized == true,
                                        selection: .vscode(path: entry.exactPath),
                                        isInThisSpace: number.map(reachable.contains) ?? false)
                }
            },
            number: { row in
                if case .vscode(let path) = row.selection { return (locator.knownWindows[path] as? AccessibilityWindow)?.number }
                return nil
            },
            locate: { try await locator.locate(path: $0, in: $1) }))
        withExtendedLifetime(resolver) {}
    }

    private static func directTarget(_ application: NSRunningApplication) -> ShortcutTarget {
        let managed = AccessibilityApplication(application: application)
        return ShortcutTarget(application: application,
                              rows: { managed.windowRows() ?? [] },
                              number: FrontWindow.number(of:),
                              locate: { _, _ in throw WindowSwitchError(messages: ["No VS Code here"]) })
    }

    /// The shortcut from the settings, posted as real key events through the real tap, panel
    /// and switcher. Keys are posted only while the application under test is in front,
    /// because otherwise they would reach the user's application.
    private static func runShortcutCheck(outputPath: String, target: ShortcutTarget) async {
        guard let shortcut = WindowShortcut.fromSettings() else { fatalError("The shortcut is turned off in System Settings") }
        let fixture = target.application
        let managed = AccessibilityApplication(application: fixture)
        for _ in 0..<100 where managed.accessibilityWindows().count < 3 { await settle(0.05) }
        let windows = managed.accessibilityWindows()
        check("the application has 3 windows", windows.count == 3, "\(windows.count)")
        guard windows.count == 3 else {
            write(outputPath)
            return
        }

        func visibleCount() -> Int {
            FrontWindow.visibleWindowCount(of: fixture.processIdentifier, in: FrontWindow.visibleOnScreen())
        }
        func frontNumber() -> Int? {
            FrontWindow.onScreenFrontToBack().first { $0.processIdentifier == fixture.processIdentifier }?.number
        }
        func bringForward() async -> Bool {
            fixture.activate()
            for _ in 0..<40 where NSWorkspace.shared.frontmostApplication != fixture { await settle(0.05) }
            return NSWorkspace.shared.frontmostApplication == fixture
        }
        func onlyShow(_ shown: [AccessibilityWindow]) async {
            for window in windows { try? window.setMinimized(!shown.contains { $0.isSame(as: window) }) }
            await settle(1.2)
            for window in shown { try? window.raise() }
            await settle(0.3)
        }
        let modifierKeys: [(flag: CGEventFlags, key: CGKeyCode)] = [(.maskCommand, 55), (.maskShift, 56), (.maskAlternate, 58), (.maskControl, 59)]
        let held = modifierKeys.filter { shortcut.modifiers & $0.flag.rawValue != 0 }
        let flags = CGEventFlags(rawValue: shortcut.modifiers)
        func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        func holdModifiers() async {
            for modifier in held { post(modifier.key, down: true, flags: flags) }
            await settle(0.1)
        }
        func releaseModifiers() async {
            for modifier in held { post(modifier.key, down: false, flags: []) }
            await settle(0.1)
        }
        func tapKey(_ key: CGKeyCode? = nil, wait: Double = 0.3) async {
            let key = key ?? CGKeyCode(shortcut.keyCode)
            post(key, down: true, flags: flags)
            post(key, down: false, flags: flags)
            await settle(wait)
        }

        let withShift = flags.union(.maskShift)
        func tapKeyGoingBack() async {
            post(56, down: true, flags: withShift)
            await settle(0.05)
            post(CGKeyCode(shortcut.keyCode), down: true, flags: withShift)
            post(CGKeyCode(shortcut.keyCode), down: false, flags: withShift)
            await settle(0.05)
            post(56, down: false, flags: flags)
            await settle(0.3)
        }

        var applied: [String] = []
        var switching: Task<Void, Never>?
        var switchInFlight: SwitchInFlight?
        var newestSwitch = 0
        var monitor: WindowShortcutMonitor?
        let area = NSScreen.main?.visibleFrame ?? .zero
        let columns = WindowLayout.accessibilityFrame(appKitFrame: area.insetBy(dx: 100, dy: 100), primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
        let panel = WindowPanelController(onApply: { application, chosen in
            applied = chosen.map(\.title)
            let switcher = WindowSwitcher(locateVSCodeWindow: target.locate)
            // As the app does it: in turn, and saying what each will leave before anything moves.
            let inFlight = SwitchInFlight(applicationIdentifier: application.identifier, processIdentifier: fixture.processIdentifier, chosen: chosen)
            switchInFlight = inFlight
            newestSwitch += 1
            let thisSwitch = newestSwitch
            monitor?.setSwitching((fixture.processIdentifier, inFlight.windowCountWhenDone))
            let previous = switching
            switching = Task { @MainActor in
                await previous?.value
                try? await switcher.apply(chosen.map(\.selection), in: application.application, columnsArea: columns)
                await FrontWindow.waitUntilSettled(fixture.processIdentifier, atMost: inFlight.windowCountWhenDone) { thisSwitch == newestSwitch }
                if thisSwitch == newestSwitch {
                    switchInFlight = nil
                    monitor?.setSwitching(nil)
                }
            }
        }, onRequestPermission: {})
        let anchor = NSRect(x: area.midX, y: area.maxY, width: 30, height: 0)
        func listed() -> [ListedApplication] {
            let list = [ListedApplication(name: "Fixture", icon: nil,
                                          windows: FrontWindow.refreshed(target.rows(), of: fixture.processIdentifier, in: FrontWindow.onScreenFrontToBack(), number: target.number),
                                          problem: nil, application: managed, bundleIdentifier: "fixture")]
            return switchInFlight?.applied(to: list) ?? list
        }
        monitor = WindowShortcutMonitor { command in
            switch command {
            case .begin: panel.beginKeyboardSession(applications: listed(), frontmostName: "Fixture", below: anchor)
            case .beginGoingBack: panel.beginKeyboardSession(applications: listed(), frontmostName: "Fixture", below: anchor, step: -1)
            case .advance: panel.moveKeyboardSelection(by: 1)
            case .retreat: panel.moveKeyboardSelection(by: -1)
            case .jump(let letter): panel.jumpKeyboardSelection(to: letter)
            case .commit: panel.commitKeyboardSelection()
            case .cancel: panel.cancelKeyboardSession()
            }
        }
        panel.onKeyboardSessionEnded = { monitor?.sessionEnded() }
        monitor?.setShortcut(shortcut)
        let letterKeys = LetterKeys.current()
        monitor?.setLetterKeys(letterKeys)
        monitor?.setFrontmost(fixture.processIdentifier)
        defer { monitor?.stop() }

        func present(_ detail: String) async -> Bool {
            let ready = await bringForward()
            if !ready { check("the fixture is in front: \(detail)", false, "\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nothing") is") }
            return ready
        }

        // What macOS does by itself, which is what this feature rests on.
        await settle(0.5)
        if await present("macOS with 3 windows") {
            let before = frontNumber()
            await holdModifiers()
            await tapKey()
            await releaseModifiers()
            await settle(0.3)
            check("without Switch, macOS switches between 3 windows", frontNumber() != before, "front stayed \(String(describing: before))")
            let afterForward = frontNumber()
            await holdModifiers()
            await tapKeyGoingBack()
            await releaseModifiers()
            await settle(0.3)
            check("without Switch, the shortcut with Shift goes back to the window before", frontNumber() == before, "\(String(describing: before)), then \(String(describing: afterForward)), then \(String(describing: frontNumber()))")
        }
        await onlyShow([windows[0]])
        if await present("macOS with 1 window") {
            let before = frontNumber()
            await holdModifiers()
            await tapKey()
            await releaseModifiers()
            await settle(0.3)
            check("without Switch, macOS does nothing with 1 window and 2 minimized",
                  frontNumber() == before && visibleCount() == 1, "front \(String(describing: before)) to \(String(describing: frontNumber())), visible \(visibleCount())")
        }
        await onlyShow([])
        if await present("macOS with no window") {
            await holdModifiers()
            await tapKey()
            await releaseModifiers()
            await settle(0.3)
            check("without Switch, macOS does nothing with every window minimized", visibleCount() == 0, "visible \(visibleCount())")
        }

        monitor?.start()
        check("the tap starts", monitor?.isRunning == true)
        await settle(0.2)

        // Two or more stay with macOS.
        await onlyShow(windows)
        if await present("3 windows") {
            let before = frontNumber()
            await holdModifiers()
            await tapKey()
            check("with 3 windows the panel stays closed", !panel.isVisible)
            await releaseModifiers()
            await settle(0.3)
            check("with 3 windows macOS still switches", frontNumber() != before, "front stayed \(String(describing: before))")
            await holdModifiers()
            await tapKeyGoingBack()
            check("with 3 windows the shortcut with Shift leaves the panel closed", !panel.isVisible)
            await releaseModifiers()
            await settle(0.3)
            check("with 3 windows nothing was chosen by Switch", applied.isEmpty, "\(applied)")
        }

        // One window: the panel, moving, and choosing on release.
        await onlyShow([windows[0]])
        if await present("1 window") {
            let before = frontNumber()
            await holdModifiers()
            await tapKey()
            check("with 1 window the panel opens", panel.isVisible)
            check("macOS does not act on the key that was taken", frontNumber() == before)
            let first = panel.keyboardRow
            let rows = panel.applications.first?.windows ?? []
            check("the panel lists all 3 windows", rows.count == 3, "\(rows.count)")
            check("the first row is not the window in front", first.map { !rows[$0].isFrontmost } == true, "row \(String(describing: first))")
            await tapKey()
            let second = panel.keyboardRow
            check("pressing again moves the row", second != first && second != nil, "\(String(describing: first)) to \(String(describing: second))")
            await tapKey()
            await tapKey()
            await tapKey()
            check("three more presses go round to the same row", panel.keyboardRow == second, "\(String(describing: panel.keyboardRow))")
            await tapKey(125)
            let afterDown = panel.keyboardRow
            check("the down arrow moves to the next row", afterDown == second.map { ($0 + 1) % rows.count }, "\(String(describing: second)) to \(String(describing: afterDown))")
            await tapKey(126)
            check("the up arrow moves back", panel.keyboardRow == second, "\(String(describing: afterDown)) to \(String(describing: panel.keyboardRow))")
            await tapKey(126)
            await tapKey(125)
            check("the panel stays open through the arrows, and macOS does not act", panel.isVisible && frontNumber() == before)
            await tapKeyGoingBack()
            let afterShift = panel.keyboardRow
            check("the shortcut with Shift moves to the row before", afterShift == second.map { ($0 + rows.count - 1) % rows.count }, "\(String(describing: second)) to \(String(describing: afterShift))")
            await tapKey()
            check("the shortcut without Shift moves on again", panel.keyboardRow == second, "\(String(describing: afterShift)) to \(String(describing: panel.keyboardRow))")
            let chosen = second.map { rows[$0].title }
            await releaseModifiers()
            await settle(0.2)
            check("releasing closes the panel", !panel.isVisible)
            check("releasing chooses the row the keys were on", applied == chosen.map { [$0] }, "\(applied) against \(String(describing: chosen))")
            await switching?.value
            await settle(0.8)
            check("the chosen window is the one on show", visibleCount() == 1, "visible \(visibleCount())")
            let shown = windows.first { !$0.isMinimized }
            check("the chosen window came back", chosen.map { shown?.title?.contains($0) == true } == true, "\(String(describing: shown?.title)) against \(String(describing: chosen))")
            check("the window that was in front is minimized", windows[0].isMinimized)
            check("the chosen window is in front", frontNumber() == shown?.number, "\(String(describing: frontNumber()))")
        }

        // The keys again straight after a switch, while both windows are still on screen.
        applied = []
        await onlyShow([windows[0]])
        if await present("the keys straight after a switch") {
            await holdModifiers()
            await tapKey()
            let firstChoice = panel.keyboardRow.flatMap { row in panel.applications.first?.windows[row] }
            for modifier in held { post(modifier.key, down: false, flags: []) }
            var bothOnScreen = false
            for _ in 0..<100 where !bothOnScreen {
                bothOnScreen = visibleCount() == 2
                if !bothOnScreen { await settle(0.01) }
            }
            check("after a switch both windows are on screen for a moment", bothOnScreen, "visible \(visibleCount())")
            await holdModifiers()
            await tapKey(nil, wait: 0.15)
            check("the keys open the panel while the windows are moving", panel.isVisible)
            let rows = panel.applications.first?.windows ?? []
            let front = rows.first(where: \.isFrontmost)
            check("the row in front is the window just chosen", front?.title == firstChoice?.title && firstChoice != nil,
                  "\(String(describing: front?.title)) against \(String(describing: firstChoice?.title))")
            let second = panel.keyboardRow.flatMap { rows.indices.contains($0) ? rows[$0] : nil }
            check("the first row is another window", second != nil && second?.title != firstChoice?.title, "\(String(describing: second?.title))")
            await releaseModifiers()
            await switching?.value
            await settle(0.5)
            let shown = windows.filter { !$0.isMinimized }
            check("the second choice is the one on show", visibleCount() == 1 && shown.count == 1 && second.map { shown.first?.title?.contains($0.title) == true } == true,
                  "visible \(visibleCount()), \(shown.map { $0.title ?? "" }) against \(String(describing: second?.title))")
            await holdModifiers()
            await tapKey()
            check("after the windows settle the row in front is the one on show", second != nil && panel.applications.first?.windows.first(where: \.isFrontmost)?.title == second?.title,
                  "\(String(describing: panel.applications.first?.windows.first(where: \.isFrontmost)?.title))")
            await tapKey(53)
            await releaseModifiers()
        }

        // A letter goes to the rows that start with it.
        applied = []
        await onlyShow([windows[0]])
        if await present("letters") {
            await holdModifiers()
            await tapKey()
            let rows = panel.applications.first?.windows ?? []
            func first(_ row: ListedWindow) -> Character? { row.title.first.flatMap { $0.lowercased().first } }
            func key(for letter: Character) -> CGKeyCode? {
                letterKeys.first { $0.value == letter }.map { CGKeyCode($0.key) }
            }
            guard let letter = rows.last.flatMap(first), let code = key(for: letter) else {
                check("the rows start with a letter on this keyboard", false, rows.map(\.title).joined(separator: ", "))
                write(outputPath)
                return
            }
            let matches = rows.indices.filter { first(rows[$0]) == letter }
            await tapKey(code)
            check("a letter goes to the first row starting with it", panel.keyboardRow == matches.first, "\(String(describing: panel.keyboardRow)) against \(matches)")
            check("a letter does not close the panel", panel.isVisible)
            await tapKey(code)
            check("the same letter again goes to the next match, or stays on the only one",
                  panel.keyboardRow == matches[1 % matches.count], "\(String(describing: panel.keyboardRow)) against \(matches)")
            if let other = letterKeys.first(where: { entry in !rows.contains { first($0) == entry.value } }) {
                let before = panel.keyboardRow
                await tapKey(CGKeyCode(other.key))
                check("a letter that starts no row moves nothing", panel.keyboardRow == before, "\(other.value): \(String(describing: panel.keyboardRow))")
            }
            await tapKey()
            await tapKey(code)
            check("after another key the letter starts from the top again", panel.keyboardRow == matches.first, "\(String(describing: panel.keyboardRow))")
            let chosen = panel.keyboardRow.map { rows[$0].title }
            await releaseModifiers()
            await settle(0.2)
            check("releasing after a letter chooses that row", applied == chosen.map { [$0] }, "\(applied)")
            await switching?.value
            await settle(0.8)
        }

        // Escape leaves everything as it was.
        applied = []
        await onlyShow([windows[0]])
        if await present("Escape") {
            await holdModifiers()
            await tapKey()
            check("the panel opens before Escape", panel.isVisible)
            await tapKey(53)
            check("Escape closes the panel", !panel.isVisible)
            await releaseModifiers()
            await settle(0.5)
            check("releasing after Escape chooses nothing", applied.isEmpty, "\(applied)")
            check("Escape changes no window", !windows[0].isMinimized && visibleCount() == 1, "visible \(visibleCount())")
        }

        // Starting with Shift goes straight to the row before the window in front.
        applied = []
        await onlyShow([windows[0]])
        if await present("starting with Shift") {
            await holdModifiers()
            await tapKeyGoingBack()
            check("with 1 window the shortcut with Shift opens the panel", panel.isVisible)
            let rows = panel.applications.first?.windows ?? []
            let front = rows.lastIndex(where: \.isFrontmost)
            check("starting with Shift chooses the row before the window in front",
                  panel.keyboardRow == front.map { ($0 + rows.count - 1) % rows.count }, "\(String(describing: panel.keyboardRow)), front \(String(describing: front))")
            let chosen = panel.keyboardRow.map { rows[$0].title }
            await releaseModifiers()
            await settle(0.2)
            check("releasing after starting with Shift chooses that row", applied == chosen.map { [$0] }, "\(applied)")
            await switching?.value
            await settle(0.8)
        }

        // Every window minimized.
        await onlyShow([])
        if await present("no window") {
            await holdModifiers()
            await tapKey()
            check("with no window the panel opens", panel.isVisible)
            check("with no window the first row is at the top", panel.keyboardRow == 0, "\(String(describing: panel.keyboardRow))")
            await releaseModifiers()
            await settle(0.2)
            await switching?.value
            await settle(0.8)
            check("with no window releasing brings one back", visibleCount() == 1, "visible \(visibleCount())")
        }

        // The tap goes when asked, and the key goes back to macOS.
        monitor?.stop()
        check("the tap stops", monitor?.isRunning == false)
        await onlyShow([windows[0]])
        if await present("after stopping") {
            await holdModifiers()
            await tapKey()
            check("with the tap stopped the panel stays closed", !panel.isVisible)
            await releaseModifiers()
        }
        write(outputPath)
    }

    // MARK: The delete key

    private static func launchFixture(extraArguments: [String] = []) async -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [RealWindowSelfTest.fixtureArgument, "1"] + extraArguments
        guard let application = try? await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) else {
            fatalError("Cannot start a fixture")
        }
        return application
    }

    private static func waitUntilTerminated(_ application: NSRunningApplication) async -> Bool {
        for _ in 0..<100 where !application.isTerminated { await settle(0.05) }
        return application.isTerminated
    }

    /// Real key events against a panel that lists nothing but this check's own fixtures,
    /// so the delete key has nothing else to quit. Keys are posted only while the panel
    /// has key focus, because otherwise they would reach the user's application.
    static func runQuitKeyCheck(outputPath: String) async {
        guard AXIsProcessTrusted() else { fatalError("No Accessibility permission") }
        let fixtures = [await launchFixture(), await launchFixture(), await launchFixture()]
        await settle(1)
        let listed = fixtures.enumerated().map { index, fixture in
            let application = AccessibilityApplication(application: fixture)
            return ListedApplication(name: "Fixture \(index)", icon: nil, windows: [], problem: nil,
                                     application: application, bundleIdentifier: "fixture.\(index)")
        }
        var pendingTermination: [pid_t: Bool] = [:]
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { notification in
            guard let quit = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let stillListed = NSWorkspace.shared.runningApplications.contains {
                $0.processIdentifier == quit.processIdentifier && !$0.isTerminated
            }
            MainActor.assumeIsolated { pendingTermination[quit.processIdentifier] = stillListed }
        }
        let panel = WindowPanelController(onApply: { _, _ in }, onRequestPermission: {})
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.show(applications: listed, hasPermission: true, frontmostName: "Fixture 1",
                   below: NSRect(x: screen.midX, y: screen.maxY, width: 30, height: 0))
        await settle(0.4)
        func press(_ code: CGKeyCode, repeating: Bool = false, flags: CGEventFlags = []) async {
            guard panel.isKeyForTesting else {
                check("the panel has key focus before key \(code)", false)
                return
            }
            let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
            down?.flags = flags
            if repeating { down?.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
            up?.flags = flags
            up?.post(tap: .cghidEventTap)
            await settle(0.5)
        }
        await press(51, repeating: true)
        check("a repeating delete key quits nothing", fixtures.allSatisfy { !$0.isTerminated })
        await press(51, flags: .maskCommand)
        check("Command+delete quits nothing", fixtures.allSatisfy { !$0.isTerminated })
        await press(51)
        check("delete quits the chosen application", await waitUntilTerminated(fixtures[1]))
        check("delete leaves the others running", !fixtures[0].isTerminated && !fixtures[2].isTerminated)
        check("the panel stays open", panel.isVisible)
        await settle(0.3)
        check("the workspace no longer lists it when told it quit",
              pendingTermination[fixtures[1].processIdentifier] == false,
              "\(pendingTermination)")
        panel.update(applications: [listed[0], listed[2]])
        check("the next application takes the row", panel.selectedApplication == 1, "\(String(describing: panel.selectedApplication))")
        await press(117)
        check("forward delete quits the chosen application", await waitUntilTerminated(fixtures[2]))
        check("forward delete leaves the other running", !fixtures[0].isTerminated)
        panel.close()
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        fixtures.forEach { $0.terminate() }
        _ = await waitUntilTerminated(fixtures[0])
        write(outputPath)
    }

    // MARK: The delete key in the running app

    private static func descendants(of element: AXUIElement) -> [AXUIElement] {
        let children = AccessibilityWindow.attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children + children.flatMap(descendants(of:))
    }

    private static func role(_ element: AXUIElement) -> String? {
        AccessibilityWindow.attribute(element, kAXRoleAttribute) as? String
    }

    /// The chosen application's row in the running panel, read from outside it.
    private static func panelApplications(pid: pid_t) -> (rows: Int, chosen: [String])? {
        let app = AXUIElementCreateApplication(pid)
        let windows = AccessibilityWindow.attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        for window in windows {
            let tables = descendants(of: window).filter { role($0) == (kAXTableRole as String) }
            guard let table = tables.first else { continue }
            let rows = AccessibilityWindow.attribute(table, kAXRowsAttribute) as? [AXUIElement] ?? []
            let selected = AccessibilityWindow.attribute(table, kAXSelectedRowsAttribute) as? [AXUIElement] ?? []
            let texts = selected.flatMap(descendants(of:)).compactMap { element -> String? in
                role(element) == (kAXStaticTextRole as String) ? AccessibilityWindow.attribute(element, kAXValueAttribute) as? String : nil
            }
            return (rows.count, texts)
        }
        return nil
    }

    /// The whole path in the running app: its icon, its own list, the key, and the row going
    /// away. The real list holds the user's applications, so the key is pressed only with
    /// this check's own application in front and read back as the chosen row. Nothing is
    /// pressed after it has quit, because the next row is the user's.
    static func runRealQuitCheck(outputPath: String) async {
        guard AXIsProcessTrusted() else { fatalError("No Accessibility permission") }
        let own = NSRunningApplication.current.processIdentifier
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tranworks.switch")
            .first(where: { $0.processIdentifier != own && $0.activationPolicy != .regular }) else {
            check("the running Switch is found", false)
            write(outputPath)
            return
        }
        let pid = running.processIdentifier
        var extras: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), "AXExtrasMenuBar" as CFString, &extras)
        guard let extras, CFGetTypeID(extras) == AXUIElementGetTypeID(),
              let item = (AccessibilityWindow.attribute(extras as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement])?.first,
              let frame = AccessibilityWindow(element: item).frame else {
            check("the icon is found", false)
            write(outputPath)
            return
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let pointerBefore = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        defer { CGWarpMouseCursorPosition(CGPoint(x: pointerBefore.x, y: primaryHeight - pointerBefore.y)) }
        let frontBefore = NSWorkspace.shared.frontmostApplication
        let othersBefore = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))

        let fixture = await launchFixture()
        for _ in 0..<100 where NSWorkspace.shared.frontmostApplication?.processIdentifier != fixture.processIdentifier {
            fixture.activate()
            await settle(0.05)
        }
        check("the fixture is in front", NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier)
        // The panel opens from the last reading, so the first opening brings in the fixture.
        await click(center)
        await settle(1)
        check("the panel opens", panelIsOpen(pid: pid))
        let name = fixture.localizedName ?? ""
        let before = panelApplications(pid: pid)
        checks.append(Check(name: "the chosen row before the key", passed: true, detail: "\(before?.chosen ?? []) of \(before?.rows ?? -1)"))
        let chosenIsFixture = before?.chosen.contains(name) == true
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier
        check("the chosen row is the fixture", chosenIsFixture, "\(before?.chosen ?? [])")
        if chosenIsFixture {
            CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: false)?.post(tap: .cghidEventTap)
            check("delete quits it", await waitUntilTerminated(fixture))
            await settle(1.2)
            let open = panelIsOpen(pid: pid)
            check("the panel stays open", open)
            if open {
                let after = panelApplications(pid: pid)
                check("its row is gone", after?.rows == (before?.rows ?? 0) - 1, "\(before?.rows ?? -1) -> \(after?.rows ?? -1)")
                check("the running Switch still has a chosen row", after?.chosen.isEmpty == false)
            }
            let othersAfter = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }.map(\.processIdentifier))
            check("every other application is still running", othersBefore.isSubset(of: othersAfter), "\(othersBefore.subtracting(othersAfter))")
            check("the running Switch is still running", !running.isTerminated)
        }
        if panelIsOpen(pid: pid) { await click(center) }
        await settle(0.6)
        check("the panel is closed at the end", !panelIsOpen(pid: pid))
        if !fixture.isTerminated {
            fixture.terminate()
            _ = await waitUntilTerminated(fixture)
        }

        // An application with unsaved work: it asks and stays, and the panel must not cover it.
        for kind in ["sheet", "alert"] {
            let asking = await launchFixture(extraArguments: [RealWindowSelfTest.askingFixtureArgument, kind])
            for _ in 0..<100 where NSWorkspace.shared.frontmostApplication?.processIdentifier != asking.processIdentifier {
                asking.activate()
                await settle(0.05)
            }
            await settle(0.5)
            await click(center)
            await settle(1)
            let chosen = panelApplications(pid: pid)?.chosen.contains(name) == true
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == asking.processIdentifier
            check("\(kind): the chosen row is the fixture", chosen)
            if chosen {
                CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true)?.post(tap: .cghidEventTap)
                CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: false)?.post(tap: .cghidEventTap)
                await settle(1.5)
                check("\(kind): the application is still running", !asking.isTerminated)
                check("\(kind): it shows a question", AccessibilityApplication(application: asking).questionCount > 0)
                check("\(kind): the panel has closed for it", !panelIsOpen(pid: pid))
            }
            if panelIsOpen(pid: pid) { await click(center) }
            asking.forceTerminate()
            _ = await waitUntilTerminated(asking)
            await settle(0.8)
        }
        frontBefore?.activate()
        write(outputPath)
    }

    // MARK: Whether a posted Command key disturbs later clicks

    /// A key event posted with flags leaves them set for the whole session (measured), and
    /// a later click then counts as Command+click, which moves a menu bar icon instead of
    /// pressing it. An event posted with explicitly empty flags clears them.
    static func clearPostedModifiers() {
        let event = CGEvent(source: nil)
        event?.type = .flagsChanged
        event?.flags = []
        event?.post(tap: .cghidEventTap)
    }

    /// Keys go only to this check's own fixture, confirmed in front before each one.
    static func runModifierProbe(outputPath: String) async {
        let own = NSRunningApplication.current.processIdentifier
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tranworks.switch")
            .first(where: { $0.processIdentifier != own && $0.activationPolicy != .regular }) else { fatalError("Switch is not running") }
        let pid = running.processIdentifier
        var extras: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), "AXExtrasMenuBar" as CFString, &extras)
        guard let extras, CFGetTypeID(extras) == AXUIElementGetTypeID(),
              let item = (AccessibilityWindow.attribute(extras as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement])?.first,
              let frame = AccessibilityWindow(element: item).frame else { fatalError("No icon") }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let before = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.height ?? 0
        let front = NSWorkspace.shared.frontmostApplication
        let fixture = await launchFixture(extraArguments: [])
        for _ in 0..<100 where NSWorkspace.shared.frontmostApplication?.processIdentifier != fixture.processIdentifier {
            fixture.activate()
            await settle(0.05)
        }
        func flags() -> String { String(CGEventSource.flagsState(.combinedSessionState).rawValue, radix: 16) }
        func clickOpens(_ name: String) async {
            await click(center)
            await settle(0.8)
            let open = panelIsOpen(pid: pid)
            checks.append(Check(name: "\(name): click opens the panel", passed: true, detail: "\(open) flags \(flags())"))
            if open {
                AXUIElementPerformAction(item, kAXPressAction as CFString)
                await settle(0.7)
            }
        }
        await clickOpens("before")
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier else {
            check("the fixture is in front", false)
            fixture.forceTerminate()
            write(outputPath)
            return
        }
        // As the VS Code check posted Command+M: flags on the key, with no Command key event.
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 46, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        await settle(0.5)
        await clickOpens("after Command+M posted with flags")
        // What the self-test posts: a Shift key going down and up.
        CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: false)?.post(tap: .cghidEventTap)
        await settle(0.5)
        await clickOpens("after a plain Shift key")
        clearPostedModifiers()
        await settle(0.5)
        await clickOpens("after clearing the posted flags")
        check("no modifier is left", CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty, flags())
        fixture.terminate()
        _ = await waitUntilTerminated(fixture)
        CGWarpMouseCursorPosition(CGPoint(x: before.x, y: height - before.y))
        front?.activate()
        write(outputPath)
    }

    // MARK: Why a click does not reach the icon

    static func runClickProbe(outputPath: String) async {
        let own = NSRunningApplication.current.processIdentifier
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tranworks.switch")
            .first(where: { $0.processIdentifier != own }) else { fatalError("Switch is not running") }
        let pid = running.processIdentifier
        var extras: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), "AXExtrasMenuBar" as CFString, &extras)
        guard let extras, CFGetTypeID(extras) == AXUIElementGetTypeID(),
              let item = (AccessibilityWindow.attribute(extras as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement])?.first,
              let frame = AccessibilityWindow(element: item).frame else { fatalError("No icon") }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        checks.append(Check(name: "frame", passed: true, detail: "\(frame) trusted \(AXIsProcessTrusted())"))
        var element: AXUIElement?
        let hit = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(center.x), Float(center.y), &element)
        var hitPid: pid_t = 0
        if let element { AXUIElementGetPid(element, &hitPid) }
        checks.append(Check(name: "element at the icon", passed: hitPid == pid, detail: "error \(hit.rawValue) pid \(hitPid) (Switch \(pid)) \(NSRunningApplication(processIdentifier: hitPid)?.localizedName ?? "")"))
        let before = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.height ?? 0
        for (name, gap) in [("short", 0.06), ("long", 0.4)] {
            post(.mouseMoved, at: center)
            await settle(0.3)
            post(.leftMouseDown, at: center)
            await settle(gap)
            post(.leftMouseUp, at: center)
            await settle(1)
            let open = panelIsOpen(pid: pid)
            check("posted click, \(name)", open)
            if open { await click(center); await settle(0.8) }
        }
        let press = AXUIElementPerformAction(item, kAXPressAction as CFString)
        await settle(1)
        let open = panelIsOpen(pid: pid)
        check("AXPress", open, "error \(press.rawValue)")
        if open { AXUIElementPerformAction(item, kAXPressAction as CFString); await settle(0.8) }
        CGWarpMouseCursorPosition(CGPoint(x: before.x, y: height - before.y))
        write(outputPath)
    }

    // MARK: Following a real VS Code window

    /// Touches the user's real VS Code: one minimized window comes back for a few seconds
    /// and goes again. Run only after telling the user. The running Switch logs what its
    /// panel shows each time it opens, and that log is what gets compared.
    static func runRealFollowCheck(outputPath: String) async {
        guard AXIsProcessTrusted(),
              let code = NSRunningApplication.runningApplications(withBundleIdentifier: VSCodeWindowCatalog.applicationBundleIdentifier).first else {
            fatalError("Needs permission and a running VS Code")
        }
        let own = NSRunningApplication.current.processIdentifier
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tranworks.switch")
            .first(where: { $0.processIdentifier != own }) else { fatalError("Switch is not running") }
        var extras: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(running.processIdentifier), "AXExtrasMenuBar" as CFString, &extras)
        guard let extras, CFGetTypeID(extras) == AXUIElementGetTypeID(),
              let item = (AccessibilityWindow.attribute(extras as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement])?.first,
              let iconFrame = AccessibilityWindow(element: item).frame else { fatalError("No icon") }
        _ = iconFrame
        let front = NSWorkspace.shared.frontmostApplication
        let managed = AccessibilityApplication(application: code)
        guard let window = managed.accessibilityWindows().first(where: \.isMinimized), let frame = window.frame else {
            check("a minimized window exists", false)
            write(outputPath)
            return
        }
        let countBefore = managed.accessibilityWindows().filter(\.isMinimized).count
        func openAndClosePanel(_ expected: Int) async {
            await settle(1.2)
            check("expecting \(expected): Accessibility agrees", managed.accessibilityWindows().filter(\.isMinimized).count == expected)
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            await settle(0.8)
            check("expecting \(expected): the panel opened", panelIsOpen(pid: running.processIdentifier))
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            await settle(0.7)
        }
        await openAndClosePanel(countBefore)
        for _ in 0..<2 {
            try? window.setMinimized(false)
            await openAndClosePanel(countBefore - 1)
            try? window.setMinimized(true)
            await openAndClosePanel(countBefore)
        }
        check("the window is minimized again", window.isMinimized)
        check("the window has its frame", window.frame == frame, "\(String(describing: window.frame)) \(frame)")
        front?.activate()
        write(outputPath)
    }

    // MARK: The running app's icon

    private static func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    }

    private static func click(_ point: CGPoint, right: Bool = false) async {
        post(.mouseMoved, at: point)
        await settle(0.12)
        post(right ? .rightMouseDown : .leftMouseDown, at: point, button: right ? .right : .left)
        await settle(0.06)
        post(right ? .rightMouseUp : .leftMouseUp, at: point, button: right ? .right : .left)
        await settle(0.5)
    }

    /// The panel is the running app's only window this wide.
    private static func panelIsOpen(pid: pid_t) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"] else { return false }
            return width >= 500
        }
    }

    static func runIconCheck(outputPath: String) async {
        guard AXIsProcessTrusted() else { fatalError("No Accessibility permission") }
        let own = NSRunningApplication.current.processIdentifier
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tranworks.switch")
            .first(where: { $0.processIdentifier != own }) else {
            check("the running Switch is found", false)
            write(outputPath)
            return
        }
        let pid = running.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var center: CGPoint?
        var extras: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, "AXExtrasMenuBar" as CFString, &extras)
        var item: AXUIElement?
        if let extras, CFGetTypeID(extras) == AXUIElementGetTypeID(),
           let children = AccessibilityWindow.attribute(extras as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement],
           let first = children.first {
            item = first
            let window = AccessibilityWindow(element: first)
            center = window.frame.map { CGPoint(x: $0.midX, y: $0.midY) }
        }
        guard let center, let item else {
            check("the icon is found through Accessibility", false)
            write(outputPath)
            return
        }
        check("the icon is found through Accessibility", true)
        checks.append(Check(name: "icon position", passed: true, detail: "\(center)"))
        let pointerBefore = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        defer {
            CGWarpMouseCursorPosition(CGPoint(x: pointerBefore.x, y: primaryHeight - pointerBefore.y))
        }

        func waitForPanel(open: Bool, _ name: String) async {
            let start = Date()
            while Date().timeIntervalSince(start) < 6 {
                if panelIsOpen(pid: pid) == open { break }
                await settle(0.02)
            }
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            check(name, panelIsOpen(pid: pid) == open, "not within 6 s")
            checks.append(Check(name: "\(name): ms", passed: true, detail: "\(elapsed)"))
        }
        check("panel starts closed", !panelIsOpen(pid: pid))
        for round in 0..<3 {
            await click(center)
            await waitForPanel(open: true, "round \(round): clicking the icon opens the panel")
            await settle(0.3)
            await click(center)
            await waitForPanel(open: false, "round \(round): clicking the icon again closes the panel")
            await settle(0.8)
        }
        await click(center)
        await waitForPanel(open: true, "clicking opens it for Escape")
        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
        await waitForPanel(open: false, "Escape closes it")
        await settle(0.8)

        await click(center, right: true)
        await settle(0.3)
        var titles: [String] = []
        if let children = AccessibilityWindow.attribute(item, kAXChildrenAttribute) as? [AXUIElement] {
            for menu in children {
                let items = AccessibilityWindow.attribute(menu, kAXChildrenAttribute) as? [AXUIElement] ?? []
                titles += items.compactMap { AccessibilityWindow.attribute($0, kAXTitleAttribute) as? String }
            }
        }
        check("right click shows Quit Switch", titles.contains(MenuBarController.quitTitle), "\(titles)")
        let large = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
            .compactMap { window -> String? in
                guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
                return "\(bounds["Width"] ?? 0)x\(bounds["Height"] ?? 0)@\(window[kCGWindowLayer as String] ?? 0)"
            }
        check("right click does not open the panel", !panelIsOpen(pid: pid), "windows \(large)")
        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
        await settle(0.5)
        check("Switch is still running after Escape", !running.isTerminated)
        await settle(0.5)
        await click(center)
        await waitForPanel(open: true, "left click opens the panel after the menu was used")
        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
        await settle(0.4)
        write(outputPath)
    }

    // MARK: Chrome on a throwaway profile

    static func runChromeCheck(outputPath: String, pid: pid_t) async {
        guard AXIsProcessTrusted(), let chrome = NSRunningApplication(processIdentifier: pid) else {
            fatalError("No permission, or no such process")
        }
        let initial = NSWorkspace.shared.frontmostApplication
        defer { initial?.activate() }
        let managed = AccessibilityApplication(application: chrome)
        var all: [AccessibilityWindow] = []
        for _ in 0..<100 {
            all = managed.accessibilityWindows()
            if all.count >= 4 { break }
            await settle(0.1)
        }
        check("the throwaway Chrome has four windows", all.count >= 4, "\(all.count)")
        guard all.count >= 4, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
              let primary = NSScreen.screens.first else {
            write(outputPath)
            return
        }
        let area = WindowLayout.accessibilityFrame(appKitFrame: screen.visibleFrame, primaryScreenHeight: primary.frame.height)
        let switcher = WindowSwitcher(locateVSCodeWindow: { _, _ in fatalError("No VS Code in this test") })
        func near(_ a: CGRect?, _ b: CGRect) -> Bool {
            guard let a else { return false }
            return abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
        }
        // Each selection involves windows minimized by the one before it: the report's case.
        let selections: [[Int]] = [[0], [1], [2, 3], [0, 1], [3], [2], [0, 2], [1, 3], [1], [0], [2, 0], [3, 1]]
        for (round, indexes) in selections.enumerated() {
            let chosen = indexes.map { all[$0] }
            do {
                try await switcher.apply(chosen.map { .direct($0) }, in: managed, columnsArea: area)
                check("round \(round) \(indexes): completes", true)
            } catch {
                check("round \(round) \(indexes): completes", false, error.localizedDescription)
            }
            await settle(0.2)
            check("round \(round): application is frontmost", NSWorkspace.shared.frontmostApplication == chosen.first.flatMap { _ in chrome })
            await settle(2.6)
            let frames = WindowLayout.columns(count: chosen.count, in: area)
            for (position, window) in chosen.enumerated() {
                check("round \(round): window \(position) is in place", near(window.frame, frames[position]) && !window.isMinimized,
                      "\(String(describing: window.frame)) expected \(frames[position]) minimized \(window.isMinimized)")
            }
            for index in all.indices where !indexes.contains(index) {
                check("round \(round): window \(index) is minimized", all[index].isMinimized)
            }
        }
        // The same again with no pause, while animations are still running.
        for round in 0..<6 {
            let chosen = [all[round % 2]]
            do {
                try await switcher.apply(chosen.map { .direct($0) }, in: managed, columnsArea: area)
                check("fast round \(round): completes", true)
            } catch {
                check("fast round \(round): completes", false, error.localizedDescription)
            }
        }
        await settle(4)
        check("fast rounds: the last chosen window is visible", !all[1].isMinimized)
        write(outputPath)
    }
}
#endif
