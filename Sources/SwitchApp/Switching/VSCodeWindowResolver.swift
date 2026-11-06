import AppKit
import ApplicationServices
import os

/// Pairs VS Code paths with windows by creation order. VS Code saves its windows in the
/// order they were created, and the window server numbers windows in the same order. Each
/// Accessibility window reports its number, so nothing here depends on where windows are.
enum VSCodeWindowOrder {
    struct ServerWindow: Equatable {
        let number: Int
        let frame: CGRect
        let layer: Int
    }

    /// One entry of VS Code's saved list. An empty or remote window has no local path.
    struct SavedWindow: Equatable {
        let path: String?
        let bounds: CGRect?
    }

    /// VS Code's own minimum (`WindowMinimumSize` in its source: 400 by 270). Its other
    /// windows are smaller: menu-bar-sized helpers, and things like the drag image.
    private static let minimumWidth: CGFloat = 400
    private static let minimumHeight: CGFloat = 270

    /// Each window whose place in the saved list is certain, with the path saved for that
    /// place. Nil when the lists cannot describe the same windows.
    ///
    /// `savedInThisRun` is false when the file is from before this run of VS Code. Its order
    /// may then be the previous run's, so every window has to be where the file says.
    static func assignments<Window>(saved: [SavedWindow],
                                    server: [ServerWindow],
                                    windows: [(window: Window, number: Int)],
                                    savedInThisRun: Bool) -> [(path: String?, window: Window)]? {
        guard !saved.isEmpty else { return nil }
        let large = server
            .filter { $0.layer == 0 && $0.frame.width >= minimumWidth && $0.frame.height >= minimumHeight }
            .sorted { $0.number < $1.number }
        let windowsByNumber = Dictionary(windows.map { ($0.number, $0.window) }, uniquingKeysWith: { first, _ in first })
        // With every saved window in Accessibility's list, a server window it does not list
        // is something else: VS Code keeps a hidden one of 500 by 500 at times (measured).
        // Otherwise those are the windows on other Spaces, and they keep their places.
        let listed = large.filter { windowsByNumber[$0.number] != nil }
        let numbered = listed.count == saved.count ? listed : (large.count == saved.count ? large : nil)
        guard let numbered else {
            return embed(saved: saved, in: large, windowsByNumber: windowsByNumber)
        }
        if !savedInThisRun {
            guard zip(saved, numbered).allSatisfy({ matches($0, $1) }) else { return nil }
        }
        return zip(saved, numbered).compactMap { entry, number in
            windowsByNumber[number.number].map { (entry.path, $0) }
        }
    }

    /// The server has windows VS Code did not save, such as a detached editor or a window
    /// opened since the last save. The saved windows are still in order among them, so each
    /// must land on a later window with the bounds saved for it. A saved window with one
    /// possible place in every such arrangement is certain. Saved bounds out of date give no
    /// arrangement, and nothing pairs until the next save.
    private static func embed<Window>(saved: [SavedWindow],
                                      in server: [ServerWindow],
                                      windowsByNumber: [Int: Window]) -> [(path: String?, window: Window)]? {
        let places = saved.indices.map { index in server.indices.filter { matches(saved[index], server[$0]) } }
        var forward = places
        for index in saved.indices.dropFirst() {
            guard let earliest = forward[index - 1].first else { return nil }
            forward[index] = forward[index].filter { $0 > earliest }
        }
        guard forward.allSatisfy({ !$0.isEmpty }) else { return nil }
        var possible = forward
        for index in saved.indices.dropLast().reversed() {
            guard let latest = possible[index + 1].last else { return nil }
            possible[index] = possible[index].filter { $0 < latest }
        }
        return saved.indices.compactMap { index in
            guard possible[index].count == 1, let window = windowsByNumber[server[possible[index][0]].number] else { return nil }
            return (saved[index].path, window)
        }
    }

    private static func matches(_ saved: SavedWindow, _ server: ServerWindow) -> Bool {
        guard let bounds = saved.bounds else { return true }
        func key(_ rect: CGRect) -> [Int] {
            [rect.minX, rect.minY, rect.width, rect.height].map { Int($0.rounded()) }
        }
        return key(bounds) == key(server.frame)
    }

    /// A check on the order, not a way to identify windows: the titles of untitled
    /// workspaces say nothing, so only named windows are compared. After a relaunch the
    /// saved list is the previous run's until the first save, and VS Code restores
    /// workspaces before folders (`doGetPathsFromLastSession`, then `doOpen`), so the order
    /// differs exactly when a folder moved, and a folder always has a name.
    static func titlesAgree(_ pairs: [(name: String?, title: String?)]) -> Bool {
        pairs.allSatisfy { pair in
            guard let name = pair.name else { return true }
            return pair.title?.precomposedStringWithCanonicalMapping.contains(name.precomposedStringWithCanonicalMapping) == true
        }
    }

    static func serverWindows(of processIdentifier: pid_t) -> [ServerWindow] {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == processIdentifier,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return ServerWindow(number: number, frame: frame, layer: layer)
        }
    }
}

/// Which windows no saved path can belong to. These get their own rows, so a window that
/// might still be paired with a path stays out: it would be listed twice.
enum VSCodeWindowsWithoutPath {
    /// Which windows have no path, and the saved paths that was worked out from. VS Code saves
    /// on every change of focus, and a save with the same paths says nothing new. A different
    /// set may mean a window has just opened a folder: it would then have a row of its own
    /// and one here, so there is no answer until the next reading.
    struct Answer<Window> {
        var windows: [Window] = []
        var savedPaths: [String]? = nil

        func windows(saved: [String]) -> [Window] {
            savedPaths == saved.sorted() ? windows : []
        }
    }

    static func select<Window>(unpairedPaths: Int,
                               unknown: [Window],
                               fromOrder: [Window],
                               isSame: (Window, Window) -> Bool) -> [Window] {
        // With every path paired, nothing is left for the other windows to belong to.
        guard unpairedPaths > 0 else { return unknown }
        return unknown.filter { window in fromOrder.contains { isSame($0, window) } }
    }
}

/// Keeps the path-to-window pairs ready before the panel is used, so that a selection
/// does not have to run the `code` command and the panel can tell which windows are
/// minimized. It polls nothing: it waits for new windows and for writes to VS Code's state
/// directory, and does nothing at all while VS Code is not running. It changes no window.
@MainActor
final class VSCodeWindowResolver {
    /// VS Code writes several times per focus change.
    private static let settleDelay: TimeInterval = 0.3
    private static let log = Logger(subsystem: "com.tranworks.switch", category: "vscode")

    private let locator: VSCodeWindowLocator
    private var running: NSRunningApplication?
    private var observer: AXObserver?
    private var stateSource: DispatchSourceFileSystemObject?
    private var stateFile: URL?
    private var stateFileDate: Date?
    private var pending: DispatchWorkItem?
    /// Which reading is the newest. An older one that finishes later says nothing new.
    private var newestReading = 0
    private var withoutPath: [AccessibilityWindow] = []
    /// The saved paths `withoutPath` was worked out from.
    private var withoutPathBasis: [String]?
    /// The windows or their pairing changed, so a list on show is out of date.
    var onChange: (() -> Void)?

    private let findApplication: () -> NSRunningApplication?
    private let supportDirectory: () throws -> URL
    private let serverWindows: (pid_t) -> [VSCodeWindowOrder.ServerWindow]

    init(locator: VSCodeWindowLocator,
         findApplication: @escaping () -> NSRunningApplication? = {
             NSRunningApplication.runningApplications(withBundleIdentifier: VSCodeWindowCatalog.applicationBundleIdentifier)
                 .first { !$0.isTerminated }
         },
         supportDirectory: @escaping () throws -> URL = { try VSCodeWindowCatalog.userSupportDirectory() },
         serverWindows: @escaping (pid_t) -> [VSCodeWindowOrder.ServerWindow] = { VSCodeWindowOrder.serverWindows(of: $0) }) {
        self.serverWindows = serverWindows
        self.locator = locator
        self.findApplication = findApplication
        self.supportDirectory = supportDirectory
    }

    func windowsWithoutPath() -> VSCodeWindowsWithoutPath.Answer<AccessibilityWindow> {
        VSCodeWindowsWithoutPath.Answer(windows: withoutPath.filter { !locator.isKnown(window: $0) },
                                        savedPaths: withoutPathBasis)
    }

    private func updateWindowsWithoutPath(entries: [VSCodeWindowEntry],
                                          windows: [AccessibilityWindow],
                                          assigned: [(path: String?, window: AccessibilityWindow)]?) {
        let found = VSCodeWindowsWithoutPath.select(
            unpairedPaths: entries.filter { !locator.isKnown(path: $0.exactPath) }.count,
            unknown: windows.filter { !locator.isKnown(window: $0) },
            fromOrder: assigned?.filter { $0.path == nil }.map(\.window) ?? [],
            isSame: { $0.isSame(as: $1) })
        let basis = entries.map(\.exactPath).sorted()
        // A list read while the paths differed has none of these rows, even if they are the same.
        let changed = basis != withoutPathBasis
            || found.count != withoutPath.count
            || !found.allSatisfy { window in withoutPath.contains { $0.isSame(as: window) } }
        withoutPath = found
        withoutPathBasis = basis
        if changed { onChange?() }
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        detach()
    }

    /// VS Code started or quit.
    func reattach() {
        detach()
        attach()
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(applicationsChanged(_:)),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationsChanged(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        attach()
    }

    /// Accessibility permission can arrive after launch, and only the panel is
    /// certain to be used then, so opening it retries a failed attachment.
    func attachIfNeeded() {
        if observer == nil { attach() }
    }

    @objc private func applicationsChanged(_ notification: Notification) {
        let changed = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard changed?.bundleIdentifier == VSCodeWindowCatalog.applicationBundleIdentifier else { return }
        reattach()
    }

    private func attach() {
        guard AXIsProcessTrusted(), let application = findApplication(), let support = try? supportDirectory() else {
            return
        }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let resolver = Unmanaged<VSCodeWindowResolver>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { resolver.scheduleResolve() }
        }
        guard AXObserverCreate(application.processIdentifier, callback, &created) == .success, let created else {
            return
        }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(created, element, kAXWindowCreatedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        running = application

        // VS Code replaces storage.json through a temporary name, so the directory is watched.
        let directory = support.appendingPathComponent("User/globalStorage", isDirectory: true)
        stateFile = directory.appendingPathComponent("storage.json")
        let descriptor = open(directory.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.stateDirectoryChanged() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            stateSource = source
        }
        stateFileDate = modificationDate()
        scheduleResolve()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        running = nil
        stateSource?.cancel()
        stateSource = nil
        pending?.cancel()
        pending = nil
        newestReading += 1
        withoutPath = []
        withoutPathBasis = nil
    }

    private func stateDirectoryChanged() {
        let date = modificationDate()
        guard date != stateFileDate else { return }
        stateFileDate = date
        scheduleResolve()
    }

    private func modificationDate() -> Date? {
        stateFile.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
    }

    private func scheduleResolve() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.resolve() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    /// One window as it was when read.
    private struct LiveWindow {
        let window: AccessibilityWindow
        let title: String?
    }

    private struct Reading {
        let stateDate: Date?
        let entries: [VSCodeWindowEntry]
        let saved: [VSCodeWindowOrder.SavedWindow]
        let windows: [AccessibilityWindow]
        let numbered: [(window: LiveWindow, number: Int)]
        let server: [VSCodeWindowOrder.ServerWindow]
        let closedPaths: [String]
    }

    private func resolve() {
        guard let running, let stateFile, let support = try? supportDirectory() else { return }
        newestReading += 1
        let reading = newestReading
        let known = locator.knownWindows
        let serverWindows = self.serverWindows
        Task { @MainActor [weak self] in
            do {
                let result = try await Self.read(running: running, support: support, stateFile: stateFile, known: known, serverWindows: serverWindows)
                guard let self, reading == self.newestReading else { return }
                self.apply(result, running: running)
            } catch {
                Self.log.error("cannot read VS Code windows: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Everything VS Code has to answer, away from the main thread: it may be busy
    /// minimizing windows, and the menu must not wait for that.
    private nonisolated static func read(running: NSRunningApplication,
                                         support: URL,
                                         stateFile: URL,
                                         known: [String: ManagedWindow],
                                         serverWindows: (pid_t) -> [VSCodeWindowOrder.ServerWindow]) async throws -> Reading {
        // Read before the state: a save made during this pass then counts as newer.
        let stateDate = try? FileManager.default.attributesOfItem(atPath: stateFile.path)[.modificationDate] as? Date
        let catalog = VSCodeWindowCatalog(supportDirectory: support)
        let entries = try catalog.openWindows()
        let saved = try catalog.windowsInCreationOrder()
        let windows = AccessibilityApplication(application: running).accessibilityWindows()
        let numbered = windows.compactMap { window in
            window.number.map { (window: LiveWindow(window: window, title: window.title), number: $0) }
        }
        return Reading(stateDate: stateDate,
                       entries: entries,
                       saved: saved,
                       windows: windows,
                       numbered: numbered,
                       server: serverWindows(running.processIdentifier),
                       closedPaths: known.filter { !$0.value.exists }.map(\.key))
    }

    private func apply(_ reading: Reading, running: NSRunningApplication) {
        let entries = reading.entries
        let windows = reading.windows
        locator.forget(paths: reading.closedPaths)
        if reading.numbered.count != windows.count {
            Self.log.error("\(windows.count - reading.numbered.count) VS Code windows report no window number")
        }
        // A file from before this run of VS Code lists the previous run's windows.
        let savedInThisRun: Bool
        if let stateDate = reading.stateDate, let launched = running.launchDate {
            savedInThisRun = stateDate > launched
        } else {
            savedInThisRun = false
        }
        var assigned = VSCodeWindowOrder.assignments(saved: reading.saved,
                                                     server: reading.server,
                                                     windows: reading.numbered,
                                                     savedInThisRun: savedInThisRun)
        let names = Dictionary(entries.map { ($0.exactPath, $0.kind == .untitledWorkspace ? nil : $0.displayName as String?) },
                               uniquingKeysWith: { first, _ in first })
        if let pairs = assigned,
           !VSCodeWindowOrder.titlesAgree(pairs.compactMap { pair in pair.path.map { (names[$0] ?? nil, pair.window.title) } }) {
            assigned = nil
        }
        let found = assigned?.map { (path: $0.path, window: $0.window.window) }
        let pairs = (found ?? []).compactMap { pair in pair.path.map { (path: $0, window: pair.window as ManagedWindow) } }
        let changes = pairs.filter { !locator.holds(path: $0.path, window: $0.window) }
        locator.correct(changes)
        #if DEBUG
        for pair in changes {
            let window = pair.window as? AccessibilityWindow
            let document = window.flatMap { AccessibilityWindow.attribute($0.element, kAXDocumentAttribute) as? String } ?? ""
            Self.log.notice("pair \(pair.path, privacy: .public) document \(document, privacy: .public)")
        }
        #endif
        updateWindowsWithoutPath(entries: entries, windows: windows, assigned: found)
        if !changes.isEmpty { onChange?() }
    }
}
