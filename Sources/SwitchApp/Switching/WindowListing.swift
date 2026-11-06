import AppKit
import ApplicationServices

struct ListedWindow {
    let title: String
    let toolTip: String?
    var isMinimized: Bool
    let selection: SelectedWindow
    /// A VS Code window with no local path, found through Accessibility alone. It is listed
    /// below the others, and reached directly because `code` has no path to take.
    var isWithoutPath = false
    /// The named group this row is listed under, such as a pterm workspace.
    var group: String? = nil
    /// In front of the application's other windows, or on show in pterm.
    var isFrontmost = false
    /// False when this row's window is known to be somewhere else, or is not known yet.
    /// The switching keys stay in the current Space, and such a row is only reached by a click.
    var isInThisSpace = true

    /// What a pin on this row is stored under, the same from one reading to the next.
    /// Other applications say nothing more lasting about a window than its title.
    var pinKey: String {
        switch selection {
        case .direct: return title
        case .vscode(let path): return path
        case .ptermTerminal(let id): return id
        }
    }

    /// Which part of the list this row is in. Pinned rows move up inside their own part.
    var section: String {
        group.map { "group:" + $0 } ?? (isWithoutPath ? "without path" : "")
    }

    func isSameWindow(as other: ListedWindow) -> Bool {
        switch (selection, other.selection) {
        case (.direct(let window), .direct(let otherWindow)): return window.isSame(as: otherWindow)
        case (.vscode(let path), .vscode(let otherPath)): return path == otherPath
        case (.ptermTerminal(let id), .ptermTerminal(let otherID)): return id == otherID
        default: return false
        }
    }

    /// Two readings with the same identities have the same thing on each row.
    var rowIdentity: String {
        if case .ptermTerminal(let id) = selection { return section + "/" + id }
        return section
    }
}

struct ListedApplication {
    let name: String
    let icon: NSImage?
    var windows: [ListedWindow]
    /// Why the windows could not be read. Shown instead of an empty list.
    let problem: String?
    let application: ManagedApplication
    var bundleIdentifier: String? = nil

    /// What a pin is stored under. An application without a bundle identifier is
    /// known only by its name.
    var identifier: String { bundleIdentifier ?? name }
}

/// A switch that has started. Until its windows have finished moving, the screen shows the
/// old window and the new one together (measured: from about 0.2 to 1.25 seconds after the
/// keys are released, with VS Code), so what is on screen does not say where things stand.
/// What the switch will leave does.
struct SwitchInFlight {
    let applicationIdentifier: String
    let processIdentifier: pid_t?
    let chosen: [ListedWindow]
    var minimizesOtherWindows = true

    /// pterm shows all its chosen terminals in its one window.
    var windowCountWhenDone: Int {
        chosen.contains { if case .ptermTerminal = $0.selection { return true } else { return false } } ? 1 : chosen.count
    }

    /// How long the panel's rows go by this switch in place of the screen: until the windows
    /// have finished minimizing. A switch that minimizes nothing has nothing to wait for, and
    /// the screen stays true.
    var settling: (processIdentifier: pid_t, windowCount: Int)? {
        guard minimizesOtherWindows, let processIdentifier else { return nil }
        return (processIdentifier, windowCountWhenDone)
    }

    /// Only the windows of this Space are minimized by a switch, and pterm says for itself
    /// which of its rows are on show.
    func applied(to applications: [ListedApplication]) -> [ListedApplication] {
        applications.map { application in
            guard application.identifier == applicationIdentifier else { return application }
            var result = application
            result.windows = application.windows.map { row in
                if case .ptermTerminal = row.selection { return row }
                let isChosen = chosen.contains { $0.isSameWindow(as: row) }
                var marked = row
                marked.isFrontmost = isChosen
                if isChosen {
                    marked.isMinimized = false
                } else if row.isInThisSpace, minimizesOtherWindows {
                    marked.isMinimized = true
                }
                return marked
            }
            return result
        }
    }
}

/// Which of an application's windows is in front. The window server is asked, because an
/// application that is not active reports no focused window (measured).
enum FrontWindow {
    struct OnScreen: Equatable {
        let processIdentifier: pid_t
        let number: Int
    }

    /// Everything on screen in this Space, from front to back. A minimized window, a hidden
    /// application and another Space's windows are not here.
    static func onScreenFrontToBack() -> [OnScreen] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t,
                  let number = info[kCGWindowNumber as String] as? Int else { return nil }
            return OnScreen(processIdentifier: owner, number: number)
        }
    }

    struct VisibleWindow: Equatable {
        let processIdentifier: pid_t
        let layer: Int
        let alpha: Double
        let size: CGSize
    }

    /// Below this a window is an application's helper, not something to switch to:
    /// LINE keeps one of 1 by 1 on screen (measured).
    private static let smallestWindowSide: CGFloat = 50

    /// Asks the window server alone. The application itself could keep the keyboard waiting.
    static func visibleOnScreen() -> [VisibleWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let alpha = info[kCGWindowAlpha as String] as? Double,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"] else { return nil }
            return VisibleWindow(processIdentifier: owner, layer: layer, alpha: alpha, size: CGSize(width: width, height: height))
        }
    }

    /// The windows on show in this Space. A minimized window and another Space's windows are
    /// not on screen, and palettes and menus are on layers of their own.
    static func visibleWindowCount(of processIdentifier: pid_t, in windows: [VisibleWindow]) -> Int {
        windows.filter {
            $0.processIdentifier == processIdentifier && $0.layer == 0 && $0.alpha > 0
                && $0.size.width >= smallestWindowSide && $0.size.height >= smallestWindowSide
        }.count
    }

    private static let settleTimeout: TimeInterval = 5
    private static let settlePollNanoseconds: UInt64 = 50_000_000

    /// Until no more than this many windows are on show. A window that an application will
    /// not minimize, or a new one, ends the wait at the time limit and not before.
    @MainActor
    static func waitUntilSettled(_ processIdentifier: pid_t, atMost count: Int, while keepWaiting: () -> Bool = { true }) async {
        let deadline = Date().addingTimeInterval(settleTimeout)
        while Date() < deadline, keepWaiting(),
              visibleWindowCount(of: processIdentifier, in: visibleOnScreen()) > count {
            try? await Task.sleep(nanoseconds: settlePollNanoseconds)
        }
    }

    /// What is in front now. The list can be from before the last switch, and the keys start
    /// from the window in front. pterm says for itself which of its rows are on show.
    static func refreshed(_ rows: [ListedWindow], of processIdentifier: pid_t, in onScreen: [OnScreen],
                          number: (ListedWindow) -> Int?) -> [ListedWindow] {
        let numbers = rows.map(number)
        let front = Self.number(among: Set(numbers.compactMap { $0 }), of: processIdentifier, in: onScreen)
        return zip(rows, numbers).map { row, rowNumber in
            if case .ptermTerminal = row.selection { return row }
            var marked = row
            marked.isFrontmost = rowNumber != nil && rowNumber == front
            return marked
        }
    }

    /// The first of these numbers. Only the listed windows count, so a palette or a hidden
    /// helper window of the same application is never the answer.
    static func number(among numbers: Set<Int>, of processIdentifier: pid_t, in onScreen: [OnScreen]) -> Int? {
        onScreen.first { $0.processIdentifier == processIdentifier && numbers.contains($0.number) }?.number
    }

    /// Marks the row of the frontmost window, given how to find a row's window number.
    static func marked(_ rows: [ListedWindow], of processIdentifier: pid_t, in onScreen: [OnScreen],
                       number: (ListedWindow) -> Int?) -> [ListedWindow] {
        let numbers = rows.map(number)
        guard let front = Self.number(among: Set(numbers.compactMap { $0 }), of: processIdentifier, in: onScreen) else { return rows }
        return zip(rows, numbers).map { row, rowNumber in
            var marked = row
            marked.isFrontmost = rowNumber == front
            return marked
        }
    }

    static func number(of row: ListedWindow) -> Int? {
        guard case .direct(let window) = row.selection else { return nil }
        return (window as? AccessibilityWindow)?.number
    }
}

/// The VS Code windows already told apart, read away from the main thread.
struct VSCodeKnownWindows {
    var byPath: [String: ManagedWindow] = [:]
    var withoutPath = VSCodeWindowsWithoutPath.Answer<AccessibilityWindow>()
}

/// The list shown when the panel opens. VS Code is listed by path from its own
/// state, and every other application by its Accessibility windows, which cover
/// the current Space only.
enum WindowListing {
    static let untitledWindowTitle = "Untitled Window"
    static let withoutPathToolTip = "Not matched to a saved folder or workspace. Listed from this Space only."

    /// What one application said when it was read.
    enum Reading {
        /// Nil means that it has no windows to list.
        case answered(ListedApplication?)
        /// It may have windows. Its rows stay as they were until it does answer.
        case noAnswer(identifier: String)
        /// Nothing yet.
        case waiting(identifier: String)
    }

    /// Rows change only when an application answers, and go only when it has quit, because
    /// the running applications are what is read.
    static func merged(_ readings: [Reading], previous: [ListedApplication]) -> [ListedApplication] {
        readings.compactMap { reading -> ListedApplication? in
            switch reading {
            case .answered(let application):
                return application
            case .noAnswer(let identifier), .waiting(let identifier):
                return previous.first { $0.identifier == identifier }
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// How long a list on show waits before showing the answers it has so far.
    private static let firstShowing: TimeInterval = 0.25

    /// Reads every application at once, away from the main thread. Each one answers over a
    /// separate connection, so one slow application delays nothing but itself. `partial`
    /// gets the list if some are still reading after a moment, and `completion` when all are done.
    @MainActor
    static func load(vscodeWindows: @MainActor () -> VSCodeKnownWindows = { VSCodeKnownWindows() },
                     previous: [ListedApplication] = [],
                     partial: (@MainActor ([ListedApplication]) -> Void)? = nil,
                     completion: @escaping @MainActor ([ListedApplication]) -> Void) {
        let trusted = AXIsProcessTrusted()
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        // Icons are read here because AppKit images are not for other threads to create.
        let icons = running.map(\.icon)
        let input = UncheckedSendable(value: (running, icons, vscodeWindows()))
        let box = UncheckedSendable(value: ResultBox(running.map { .waiting(identifier: $0.bundleIdentifier ?? $0.localizedName ?? "") }))
        let onMain = UncheckedSendable(value: (previous, partial, completion))
        DispatchQueue.main.asyncAfter(deadline: .now() + firstShowing) {
            MainActor.assumeIsolated {
                if !box.value.isDone { onMain.value.1?(merged(box.value.values, previous: onMain.value.0)) }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let (running, icons, known) = input.value
            let onScreen = FrontWindow.onScreenFrontToBack()
            DispatchQueue.concurrentPerform(iterations: running.count) { index in
                let application = running[index]
                let reading: Reading
                if application.bundleIdentifier == VSCodeWindowCatalog.applicationBundleIdentifier {
                    reading = .answered(vscode(application, icon: icons[index], known: known, onScreen: onScreen))
                } else if !trusted {
                    reading = .answered(nil)
                } else if application.bundleIdentifier == PtermBridgeClient.applicationBundleIdentifier {
                    reading = ptermListed(application, icon: icons[index], onScreen: onScreen)
                } else {
                    reading = accessibilityListed(application, icon: icons[index], onScreen: onScreen)
                }
                box.value.set(reading, at: index)
            }
            box.value.finish()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    onMain.value.2(merged(box.value.values, previous: onMain.value.0))
                }
            }
        }
    }

    private struct UncheckedSendable<Value>: @unchecked Sendable {
        let value: Value
    }

    private final class ResultBox {
        private let lock = NSLock()
        private var readings: [Reading]
        private var done = false

        init(_ readings: [Reading]) {
            self.readings = readings
        }

        var values: [Reading] {
            lock.lock()
            defer { lock.unlock() }
            return readings
        }

        var isDone: Bool {
            lock.lock()
            defer { lock.unlock() }
            return done
        }

        func set(_ value: Reading, at index: Int) {
            lock.lock()
            readings[index] = value
            lock.unlock()
        }

        func finish() {
            lock.lock()
            done = true
            lock.unlock()
        }
    }

    private static func accessibilityListed(_ running: NSRunningApplication, icon: NSImage?, onScreen: [FrontWindow.OnScreen]) -> Reading {
        let application = AccessibilityApplication(application: running)
        let identifier = running.bundleIdentifier ?? running.localizedName ?? ""
        guard let rows = application.windowRows() else { return .noAnswer(identifier: identifier) }
        guard !rows.isEmpty else { return .answered(nil) }
        return .answered(ListedApplication(
            name: running.localizedName ?? running.bundleIdentifier ?? "Application",
            icon: icon,
            windows: FrontWindow.marked(rows, of: running.processIdentifier, in: onScreen, number: FrontWindow.number(of:)),
            problem: nil,
            application: application,
            bundleIdentifier: running.bundleIdentifier))
    }

    /// A version of pterm that has no bridge has windows like any other application. One that
    /// has it but is too busy to answer may still have terminals, so its rows stay.
    private static func ptermListed(_ running: NSRunningApplication, icon: NSImage?, onScreen: [FrontWindow.OnScreen]) -> Reading {
        let identifier = running.bundleIdentifier ?? running.localizedName ?? ""
        do {
            guard let client = PtermBridgeClient.forApplication(processIdentifier: running.processIdentifier) else {
                return accessibilityListed(running, icon: icon, onScreen: onScreen)
            }
            let rows = ptermRows(try client.list())
            guard !rows.isEmpty else { return accessibilityListed(running, icon: icon, onScreen: onScreen) }
            return .answered(ListedApplication(
                name: running.localizedName ?? identifier,
                icon: icon,
                windows: rows,
                problem: nil,
                application: AccessibilityApplication(application: running),
                bundleIdentifier: running.bundleIdentifier))
        } catch PtermBridgeClient.Failure.noAnswer {
            return .noAnswer(identifier: identifier)
        } catch {
            return accessibilityListed(running, icon: icon, onScreen: onScreen)
        }
    }

    /// A terminal that is not on show in pterm counts as minimized, whichever view pterm is in.
    static func ptermRows(_ terminals: [PtermBridgeClient.Terminal]) -> [ListedWindow] {
        terminals.map { terminal in
            ListedWindow(title: terminal.title,
                         toolTip: nil,
                         isMinimized: !terminal.isDisplayed,
                         selection: .ptermTerminal(id: terminal.id),
                         group: terminal.workspace,
                         isFrontmost: terminal.isDisplayed)
        }
    }

    private static func listed(withoutPath windows: [AccessibilityWindow]) -> [ListedWindow] {
        windows.map { window in
            let title = window.title ?? ""
            return ListedWindow(title: title.isEmpty ? untitledWindowTitle : title,
                                toolTip: withoutPathToolTip,
                                isMinimized: window.isMinimized,
                                selection: .direct(window),
                                isWithoutPath: true)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func vscode(_ running: NSRunningApplication, icon: NSImage?, known: VSCodeKnownWindows, onScreen: [FrontWindow.OnScreen]) -> ListedApplication {
        let application = AccessibilityApplication(application: running)
        let name = running.localizedName ?? "Visual Studio Code"
        do {
            let support = try VSCodeWindowCatalog.userSupportDirectory()
            let entries = try VSCodeWindowCatalog(supportDirectory: support).openWindows()
            let titles = VSCodeWindowCatalog.displayTitles(for: entries)
            // Accessibility lists this Space's windows and the minimized ones, and only
            // these can be told from a window on another Space.
            let reachable = Set(application.accessibilityWindows().compactMap(\.number))
            let windows = zip(entries, titles).map { entry, title in
                let number = (known.byPath[entry.exactPath] as? AccessibilityWindow)?.number
                return ListedWindow(title: title, toolTip: entry.target.path,
                                    isMinimized: known.byPath[entry.exactPath]?.isMinimized == true,
                                    selection: .vscode(path: entry.exactPath),
                                    isInThisSpace: number.map(reachable.contains) ?? false)
            } + listed(withoutPath: known.withoutPath.windows(saved: entries.map(\.exactPath)).filter(\.exists))
            let marked = FrontWindow.marked(windows, of: running.processIdentifier, in: onScreen) { row in
                if case .vscode(let path) = row.selection {
                    return (known.byPath[path] as? AccessibilityWindow)?.number
                }
                return FrontWindow.number(of: row)
            }
            return ListedApplication(name: name, icon: icon, windows: marked, problem: nil, application: application, bundleIdentifier: running.bundleIdentifier)
        } catch {
            return ListedApplication(name: name, icon: icon, windows: [],
                                     problem: "Cannot read VS Code windows: \(error)", application: application, bundleIdentifier: running.bundleIdentifier)
        }
    }
}
