import Foundation
import os

/// A window of another application that Switch can act on.
protocol ManagedWindow: AnyObject {
    var isMinimized: Bool { get }
    var isFullScreen: Bool { get }
    /// False once the window has been closed or its application has quit.
    var exists: Bool { get }
    func isSame(as other: ManagedWindow) -> Bool
    func setMinimized(_ minimized: Bool) throws
    func raise() throws
    func setFrame(_ frame: CGRect) throws
}

/// The application whose windows a selection belongs to.
protocol ManagedApplication: AnyObject {
    func windows() -> [ManagedWindow]
    func focusedWindow() -> ManagedWindow?
    var isFrontmost: Bool { get }
    func activate()
    /// Asks the application to quit, as its Quit menu item does, so it can still ask
    /// about unsaved work. False when the request could not be sent.
    func terminate() -> Bool
    var isTerminated: Bool { get }
    /// Dialogs and sheets on show. Some applications show one all the time, so only a
    /// rise says that it is asking a question, such as about unsaved work.
    var questionCount: Int { get }
}

/// How a chosen window is reached. VS Code windows are chosen by path, because
/// the titles of untitled workspaces cannot tell them apart.
enum SelectedWindow {
    case direct(ManagedWindow)
    case vscode(path: String)
    /// A terminal inside pterm, which arranges its own terminals in its one window.
    case ptermTerminal(id: String)
}

enum WindowLayout {
    /// Equal columns from left to right, in the order the windows were chosen.
    static func columns(count: Int, in area: CGRect) -> [CGRect] {
        precondition(count > 0, "A layout needs at least one window")
        let width = (area.width / CGFloat(count)).rounded(.down)
        return (0..<count).map { index in
            CGRect(x: area.minX + CGFloat(index) * width, y: area.minY, width: width, height: area.height)
        }
    }

    /// The screen under a point. `CGRect.contains` leaves out the top and right edges,
    /// and the pointer can rest exactly there, so those edges count. A point on no screen,
    /// as can happen at the seam between displays, belongs to the nearest one.
    static func screenIndex(containing point: CGPoint, in frames: [CGRect]) -> Int? {
        func distance(_ frame: CGRect) -> CGFloat {
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            return dx * dx + dy * dy
        }
        return frames.indices.min { distance(frames[$0]) < distance(frames[$1]) }
    }

    /// Converts an AppKit rectangle (origin at the bottom left of the primary
    /// screen) to Accessibility coordinates (origin at its top left).
    static func accessibilityFrame(appKitFrame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: appKitFrame.minX,
               y: primaryScreenHeight - appKitFrame.maxY,
               width: appKitFrame.width,
               height: appKitFrame.height)
    }
}

struct WindowSwitchError: LocalizedError, Equatable {
    let messages: [String]
    var errorDescription: String? { messages.joined(separator: "\n") }
}

/// Applies a selection: the chosen windows come to the front and share the whole
/// area in equal columns (a single window fills it), and the application's other
/// windows are minimized. Windows of other applications are never touched.
///
/// Not on the main thread: every request waits for the application's answer, and an
/// application minimizing windows takes seconds to give one. The menu must not wait for that.
struct WindowSwitcher {
    private static let log = Logger(subsystem: "com.tranworks.switch", category: "timing")
    private static let restoreTimeout: TimeInterval = 5
    private static let restorePollNanoseconds: UInt64 = 20_000_000
    private static let busyRetryNanoseconds: UInt64 = 50_000_000
    private static let lateWindowWait: TimeInterval = 0.8
    private static let lateWindowPollNanoseconds: UInt64 = 200_000_000

    let locateVSCodeWindow: (String, ManagedApplication) async throws -> ManagedWindow
    /// True when another selection is waiting, which ends the wait for late windows.
    var newerSelectionIsWaiting: @MainActor () -> Bool = { false }
    /// Has pterm show these terminals, and gives the one window they are shown in.
    var showPtermTerminals: ([String], ManagedApplication) async throws -> ManagedWindow = { terminals, application in
        try await PtermSelection.show(terminals: terminals, in: application)
    }

    func apply(_ selection: [SelectedWindow], in application: ManagedApplication, columnsArea: CGRect) async throws {
        let start = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        let chosen = try await resolve(selection, in: application)
        Self.log.notice("located \(chosen.count) windows at \(elapsed()) ms")

        let restoring = chosen.filter(\.isMinimized)
        for window in restoring {
            try await retryingWhileBusy(window) { try window.setMinimized(false) }
        }
        try await waitUntilRestored(restoring)
        Self.log.notice("restored \(restoring.count) windows at \(elapsed()) ms")
        // A full screen window owns its Space and cannot be given a frame.
        let arranged = chosen.filter { !$0.isFullScreen }
        if !arranged.isEmpty {
            for (window, frame) in zip(arranged, WindowLayout.columns(count: arranged.count, in: columnsArea)) {
                try await retryingWhileBusy(window) { try window.setFrame(frame) }
            }
        }
        // An application handles minimizing one animated window at a time, about 0.6
        // seconds each, and anything requested later waits behind that. So the chosen
        // windows come forward first. Windows raised while the application is inactive
        // stay behind other applications, so the application has to be active first.
        await MainActor.run { application.activate() }
        try await waitUntilFrontmost(application)
        for window in chosen.reversed() {
            do {
                try await retryingWhileBusy(window) { try window.raise() }
            } catch {
                Self.log.error("raise failed: \(error.localizedDescription, privacy: .public) exists=\(window.exists) minimized=\(window.isMinimized) fullScreen=\(window.isFullScreen) frontmost=\(application.isFrontmost)")
                throw error
            }
        }
        Self.log.notice("raised at \(elapsed()) ms")

        // One failure does not stop the rest; every failure is reported.
        var failures: [String] = []
        for window in application.windows()
        where !window.isMinimized && !chosen.contains(where: { $0.isSame(as: window) }) {
            do {
                try await retryingWhileBusy(window) { try window.setMinimized(true) }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        Self.log.notice("requested minimizing at \(elapsed()) ms")

        // A window still coming back from an earlier selection reads as minimized above,
        // and arrives after this pass. The chosen windows are already in place, so the
        // brief wait here delays nothing the user is waiting for.
        let deadline = Date().addingTimeInterval(Self.lateWindowWait)
        while Date() < deadline, await !newerSelectionIsWaiting() {
            try await Task.sleep(nanoseconds: Self.lateWindowPollNanoseconds)
            for window in application.windows()
            where !window.isMinimized && !chosen.contains(where: { $0.isSame(as: window) }) {
                try? window.setMinimized(true)
            }
        }
        if !failures.isEmpty {
            throw WindowSwitchError(messages: failures)
        }
    }

    /// An application that is still busy answers again in a moment. A window that has gone
    /// never will, so only a window that still exists is waited for.
    private func retryingWhileBusy(_ window: ManagedWindow, _ action: () throws -> Void) async throws {
        let deadline = Date().addingTimeInterval(Self.restoreTimeout)
        while true {
            do {
                try action()
                return
            } catch let error as AccessibilityActionError where error.meansBusy && window.exists && Date() < deadline {
                try await Task.sleep(nanoseconds: Self.busyRetryNanoseconds)
            }
        }
    }

    private func waitUntilFrontmost(_ application: ManagedApplication) async throws {
        let deadline = Date().addingTimeInterval(Self.restoreTimeout)
        while !application.isFrontmost {
            guard Date() < deadline else {
                throw WindowSwitchError(messages: ["The application did not come to the front."])
            }
            try await Task.sleep(nanoseconds: Self.restorePollNanoseconds)
        }
    }

    /// Restoring returns before the window is back, and raising a window that is
    /// still on its way back fails with kAXErrorCannotComplete.
    private func waitUntilRestored(_ windows: [ManagedWindow]) async throws {
        let deadline = Date().addingTimeInterval(Self.restoreTimeout)
        while windows.contains(where: \.isMinimized) {
            guard Date() < deadline else {
                throw WindowSwitchError(messages: ["A window did not come back from the Dock."])
            }
            try await Task.sleep(nanoseconds: Self.restorePollNanoseconds)
        }
    }

    private func resolve(_ selection: [SelectedWindow], in application: ManagedApplication) async throws -> [ManagedWindow] {
        // However many are chosen, they are one request and one window. The window then fills
        // the screen as any single window does, and pterm decides what is inside it.
        let terminals = selection.compactMap { selected -> String? in
            if case .ptermTerminal(let id) = selected { return id }
            return nil
        }
        if !terminals.isEmpty {
            return [try await showPtermTerminals(terminals, application)]
        }
        var resolved: [ManagedWindow] = []
        for selected in selection {
            let window: ManagedWindow
            switch selected {
            case .ptermTerminal:
                continue
            case .direct(let direct):
                window = direct
            case .vscode(let path):
                window = try await locateVSCodeWindow(path, application)
                // Two paths resolving to one window means focus did not follow the
                // request, and minimizing based on it would hide the wrong window.
                if resolved.contains(where: { $0.isSame(as: window) }) {
                    throw WindowSwitchError(messages: ["VS Code did not focus a separate window for \(path)."])
                }
            }
            resolved.append(window)
        }
        return resolved
    }
}

/// Finds the AX window for a VS Code path. The first time, VS Code focuses the
/// window through the `code` command, and the window that received focus is the one
/// for that path. The command takes over a second, so the window is remembered and
/// later selections skip it while the window still exists.
@MainActor
final class VSCodeWindowLocator {
    /// Time for focus to reach VS Code after the command exits.
    static let focusSettleNanoseconds: UInt64 = 300_000_000
    static let focusPollNanoseconds: UInt64 = 20_000_000
    static let focusTimeout: TimeInterval = 2

    private let opener: VSCodeWindowOpening
    private let applicationURL: () throws -> URL
    private var known: [String: ManagedWindow] = [:]

    init(opener: VSCodeWindowOpening, applicationURL: @escaping () throws -> URL) {
        self.opener = opener
        self.applicationURL = applicationURL
    }

    /// A window can open another workspace, which removes its old path from the
    /// list. Forgetting that path keeps it from reaching the wrong window.
    func forgetPaths(notIn paths: Set<String>) {
        known = known.filter { paths.contains($0.key) }
    }

    /// Without this a closed window would keep its path "known", and the path could
    /// not be paired with the new window when the workspace is opened again.
    func forgetClosedWindows() {
        known = known.filter { $0.value.exists }
    }

    func isMinimized(path: String) -> Bool {
        known[path]?.isMinimized == true
    }

    /// What the known windows are, for reading them away from the main thread.
    var knownWindows: [String: ManagedWindow] { known }

    func forget(paths: [String]) {
        for path in paths { known[path] = nil }
    }

    func isKnown(path: String) -> Bool { known[path] != nil }

    func isKnown(window: ManagedWindow) -> Bool {
        known.values.contains { $0.isSame(as: window) }
    }

    func holds(path: String, window: ManagedWindow) -> Bool {
        known[path]?.isSame(as: window) == true
    }

    /// Replaces what is known about these paths and windows.
    func correct(_ pairs: [(path: String, window: ManagedWindow)]) {
        for pair in pairs {
            known = known.filter { !$0.value.isSame(as: pair.window) }
            known[pair.path] = pair.window
        }
    }

    func locate(path: String, in application: ManagedApplication) async throws -> ManagedWindow {
        // Windows on another Space are not in the list, so they take the command,
        // which is also what switches to their Space.
        if let window = known[path], await Self.isListed(window, in: application) {
            return window
        }
        let window = try await focusThroughCommand(path: path, in: application)
        known = known.filter { !$0.value.isSame(as: window) }
        known[path] = window
        return window
    }

    // These wait for the application's answer, so they do not run on the main thread.

    private nonisolated static func isListed(_ window: ManagedWindow, in application: ManagedApplication) async -> Bool {
        window.exists && application.windows().contains { $0.isSame(as: window) }
    }

    private nonisolated static func isFrontmost(_ application: ManagedApplication) async -> Bool {
        application.isFrontmost
    }

    private nonisolated static func focusedWindow(of application: ManagedApplication) async -> ManagedWindow? {
        application.focusedWindow().flatMap { $0.isMinimized ? nil : $0 }
    }

    /// Only the command's exit says the request has been handled. A change of focus
    /// before that may belong to something else, such as a window still coming back
    /// from an earlier selection, and pairing on it would hide the wrong window.
    private func focusThroughCommand(path: String, in application: ManagedApplication) async throws -> ManagedWindow {
        let url = try applicationURL()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            opener.open(path: path, withApplicationAt: url) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        try await Task.sleep(nanoseconds: Self.focusSettleNanoseconds)
        // A window coming back from the Dock has no focus until its animation ends. And
        // with every window minimized, the command restores one without making VS Code
        // active (measured), and an inactive application reports no focused window.
        if await !Self.isFrontmost(application) { application.activate() }
        let deadline = Date().addingTimeInterval(Self.focusTimeout)
        while true {
            if let window = await Self.focusedWindow(of: application) {
                return window
            }
            guard Date() < deadline else {
                throw WindowSwitchError(messages: ["VS Code reported no focused window for \(path)."])
            }
            try await Task.sleep(nanoseconds: Self.focusPollNanoseconds)
        }
    }
}
