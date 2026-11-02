import AppKit
import Security
import XCTest
@testable import SwitchApp

private final class FakeWindow: ManagedWindow {
    let name: String
    var isMinimized: Bool
    var frame: CGRect?
    var failure: Error?
    /// How many more requests answer that the application is busy.
    var busyAnswers = 0
    private let log: EventLog

    private func answerBusy() throws {
        guard busyAnswers > 0 else { return }
        busyAnswers -= 1
        throw AccessibilityActionError(action: "move", code: AXError.cannotComplete.rawValue)
    }

    init(_ name: String, minimized: Bool = false, log: EventLog) {
        self.name = name
        self.isMinimized = minimized
        self.log = log
    }

    var isFullScreen = false
    var exists = true

    func isSame(as other: ManagedWindow) -> Bool { self === other }

    func setMinimized(_ minimized: Bool) throws {
        if let failure { throw failure }
        isMinimized = minimized
        log.events.append("\(minimized ? "minimize" : "restore") \(name)")
    }

    func raise() throws {
        try answerBusy()
        log.events.append("raise \(name)")
    }

    func setFrame(_ frame: CGRect) throws {
        if let failure { throw failure }
        try answerBusy()
        self.frame = frame
        log.events.append("frame \(name)")
    }
}

private final class EventLog { var events: [String] = [] }

/// Reports itself minimized for a few reads after a restore request, as a real
/// window does during the animation.
private final class SlowRestoringWindow: ManagedWindow {
    private let log: EventLog
    private var readsUntilRestored = -1
    init(log: EventLog) { self.log = log }

    var isMinimized: Bool {
        if readsUntilRestored < 0 { return true }
        if readsUntilRestored == 0 { return false }
        readsUntilRestored -= 1
        if readsUntilRestored == 0 { log.events.append("restore finished") }
        return readsUntilRestored > 0
    }

    let isFullScreen = false
    let exists = true
    func isSame(as other: ManagedWindow) -> Bool { self === other }
    func setMinimized(_ minimized: Bool) throws {
        log.events.append("restore requested")
        readsUntilRestored = 3
    }
    func raise() throws { log.events.append("raise") }
    func setFrame(_ frame: CGRect) throws { log.events.append("frame") }
}

private final class FakeApplication: ManagedApplication {
    var all: [ManagedWindow] = []
    var focused: FakeWindow?
    private let log: EventLog
    init(log: EventLog) { self.log = log }
    func windows() -> [ManagedWindow] { all }
    var focusedOnlyWhenFrontmost: FakeWindow?
    func focusedWindow() -> ManagedWindow? {
        if let focusedOnlyWhenFrontmost { return isFrontmost ? focusedOnlyWhenFrontmost : nil }
        return focused
    }
    var isFrontmost: Bool = false
    func activate() {
        log.events.append("activate")
        isFrontmost = true
    }
    var terminateRequests = 0
    var terminateSucceeds = true
    var isTerminated = false
    var questionCount = 0
    func terminate() -> Bool {
        terminateRequests += 1
        return terminateSucceeds
    }
}

private final class ImmediateOpener: VSCodeWindowOpening {
    var opened: [String] = []
    var failure: Error?
    var onOpen: ((String) -> Void)?
    func open(path target: String, withApplicationAt applicationURL: URL, completion: @escaping @MainActor (Error?) -> Void) {
        opened.append(target)
        onOpen?(target)
        let failure = failure
        Task { @MainActor in completion(failure) }
    }
}

private final class DeferredOpener: VSCodeWindowOpening {
    var onOpen: (() -> Void)?
    var beforeFinishing: (() -> Void)?
    func open(path: String, withApplicationAt applicationURL: URL, completion: @escaping @MainActor (Error?) -> Void) {
        onOpen?()
        let finish = beforeFinishing
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            finish?()
            completion(nil)
        }
    }
}

@MainActor
final class WindowSwitcherTests: XCTestCase {
    private struct Stub: LocalizedError { var errorDescription: String? { "stub failure" } }

    private let area = CGRect(x: 0, y: 25, width: 1000, height: 700)
    private let noVSCode = WindowSwitcher(locateVSCodeWindow: { _, _ in preconditionFailure("not a VS Code selection") })

    func testThePointerOnAScreenEdgeBelongsToThatScreen() {
        let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let right = CGRect(x: 1728, y: 0, width: 1920, height: 1080)
        let above = CGRect(x: 0, y: 1117, width: 1920, height: 1080)
        let frames = [main, right, above]
        XCTAssertEqual(WindowLayout.screenIndex(containing: CGPoint(x: 100, y: 100), in: frames), 0)
        // Regression: CGRect.contains is false on the top edge, which crashed.
        XCTAssertEqual(WindowLayout.screenIndex(containing: CGPoint(x: 100, y: 1117), in: [main]), 0)
        XCTAssertEqual(WindowLayout.screenIndex(containing: CGPoint(x: 1728, y: 500), in: [main]), 0)
        XCTAssertEqual(WindowLayout.screenIndex(containing: CGPoint(x: 2000, y: 500), in: frames), 1)
        XCTAssertEqual(WindowLayout.screenIndex(containing: CGPoint(x: 500, y: 1500), in: frames), 2)
        XCTAssertEqual(WindowLayout.screenIndex(containing: CGPoint(x: 5000, y: 500), in: frames), 1)
        XCTAssertNil(WindowLayout.screenIndex(containing: .zero, in: []))
    }

    func testColumnsOnAScreenLeftOfOrAboveThePrimaryAreInItsCoordinates() {
        // With a display to the left, x is negative. With one above, Accessibility y is negative.
        let left = WindowLayout.accessibilityFrame(appKitFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055), primaryScreenHeight: 1117)
        XCTAssertEqual(left, CGRect(x: -1920, y: 62, width: 1920, height: 1055))
        XCTAssertEqual(WindowLayout.columns(count: 2, in: left).map(\.minX), [-1920, -960])
        let above = WindowLayout.accessibilityFrame(appKitFrame: CGRect(x: 0, y: 1117, width: 1920, height: 1055), primaryScreenHeight: 1117)
        XCTAssertEqual(above, CGRect(x: 0, y: -1055, width: 1920, height: 1055))
    }

    func testANewerSelectionEndsTheWaitForLateWindows() async throws {
        let log = EventLog()
        let application = FakeApplication(log: log)
        let chosen = FakeWindow("chosen", log: log)
        application.all = [chosen]
        let switcher = WindowSwitcher(locateVSCodeWindow: { _, _ in preconditionFailure("not a VS Code selection") },
                                      newerSelectionIsWaiting: { true })
        let start = Date()
        try await switcher.apply([.direct(chosen)], in: application, columnsArea: area)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)
    }

    func testColumnsAreEqualAndFollowTheGivenOrder() {
        let frames = WindowLayout.columns(count: 3, in: CGRect(x: 100, y: 25, width: 900, height: 700))
        XCTAssertEqual(frames, [CGRect(x: 100, y: 25, width: 300, height: 700),
                                CGRect(x: 400, y: 25, width: 300, height: 700),
                                CGRect(x: 700, y: 25, width: 300, height: 700)])
    }

    func testAccessibilityFrameFlipsTheVerticalAxis() {
        let frame = WindowLayout.accessibilityFrame(appKitFrame: CGRect(x: 0, y: 50, width: 1000, height: 900), primaryScreenHeight: 1000)
        XCTAssertEqual(frame, CGRect(x: 0, y: 50, width: 1000, height: 900))
        let upper = WindowLayout.accessibilityFrame(appKitFrame: CGRect(x: 0, y: 1000, width: 800, height: 500), primaryScreenHeight: 1000)
        XCTAssertEqual(upper.minY, -500)
    }

    func testOneChosenWindowFillsTheAreaAndTheOthersAreMinimized() async throws {
        let log = EventLog()
        let application = FakeApplication(log: log)
        let chosen = FakeWindow("chosen", log: log), other = FakeWindow("other", log: log)
        application.all = [other, chosen]

        try await noVSCode.apply([.direct(chosen)], in: application, columnsArea: area)

        XCTAssertEqual(chosen.frame, area)
        XCTAssertFalse(chosen.isMinimized)
        XCTAssertTrue(other.isMinimized)
        XCTAssertEqual(log.events, ["frame chosen", "activate", "raise chosen", "minimize other"])
    }

    func testSeveralChosenWindowsShareTheAreaInClickOrder() async throws {
        let log = EventLog()
        let application = FakeApplication(log: log)
        let first = FakeWindow("first", log: log), second = FakeWindow("second", log: log), other = FakeWindow("other", log: log)
        application.all = [second, other, first]

        try await noVSCode.apply([.direct(first), .direct(second)], in: application, columnsArea: area)

        XCTAssertEqual(first.frame, CGRect(x: 0, y: 25, width: 500, height: 700))
        XCTAssertEqual(second.frame, CGRect(x: 500, y: 25, width: 500, height: 700))
        XCTAssertTrue(other.isMinimized)
        XCTAssertFalse(first.isMinimized)
        XCTAssertFalse(second.isMinimized)
    }

    func testMinimizedChoiceIsRestoredAndAlreadyMinimizedOthersAreLeftAlone() async throws {
        let log = EventLog()
        let application = FakeApplication(log: log)
        let chosen = FakeWindow("chosen", minimized: true, log: log), idle = FakeWindow("idle", minimized: true, log: log)
        application.all = [chosen, idle]

        try await noVSCode.apply([.direct(chosen)], in: application, columnsArea: area)

        XCTAssertEqual(log.events, ["restore chosen", "frame chosen", "activate", "raise chosen"])
    }

    func testABusyApplicationIsWaitedForWhileArrangingAndRaising() async throws {
        // Regression: Word answered -25204 to a move just after its windows came back.
        let log = EventLog()
        let application = FakeApplication(log: log)
        let window = FakeWindow("doc", log: log)
        window.busyAnswers = 3
        application.all = [window]

        try await noVSCode.apply([.direct(window)], in: application, columnsArea: area)

        XCTAssertEqual(window.frame, area)
        XCTAssertEqual(log.events, ["frame doc", "activate", "raise doc"])
    }

    func testAWindowThatHasGoneIsNotWaitedFor() async throws {
        let log = EventLog()
        let application = FakeApplication(log: log)
        let window = FakeWindow("doc", log: log)
        window.busyAnswers = 1_000_000
        window.exists = false
        application.all = [window]

        let start = Date()
        do {
            try await noVSCode.apply([.direct(window)], in: application, columnsArea: area)
            XCTFail("the error should reach the user")
        } catch let error as AccessibilityActionError {
            XCTAssertTrue(error.meansBusy)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testOtherErrorsAreReportedAtOnce() async throws {
        let log = EventLog()
        let application = FakeApplication(log: log)
        let window = FakeWindow("doc", log: log)
        window.failure = AccessibilityActionError(action: "move", code: AXError.attributeUnsupported.rawValue)
        application.all = [window]

        let start = Date()
        do {
            try await noVSCode.apply([.direct(window)], in: application, columnsArea: area)
            XCTFail("the error should reach the user")
        } catch is AccessibilityActionError {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testAChosenWindowIsBackBeforeItIsRaised() async throws {
        // Regression: Chrome answered kAXErrorCannotComplete to a raise right after a restore.
        let log = EventLog()
        let application = FakeApplication(log: log)
        let window = SlowRestoringWindow(log: log)
        application.all = [window]

        try await noVSCode.apply([.direct(window)], in: application, columnsArea: area)

        XCTAssertEqual(log.events, ["restore requested", "restore finished", "frame", "activate", "raise"])
    }

    func testChosenWindowsComeForwardBeforeAnythingIsMinimized() async throws {
        // Regression: minimizing first delayed the chosen windows by 0.6 s per window.
        let log = EventLog()
        let application = FakeApplication(log: log)
        let chosen = FakeWindow("chosen", log: log), a = FakeWindow("a", log: log), b = FakeWindow("b", log: log)
        application.all = [a, chosen, b]
        try await noVSCode.apply([.direct(chosen)], in: application, columnsArea: area)
        XCTAssertEqual(log.events, ["frame chosen", "activate", "raise chosen", "minimize a", "minimize b"])
    }

    func testEveryMinimizeFailureIsReportedAndTheRestStillRun() async throws {
        let log = EventLog()
        let application = FakeApplication(log: log)
        let chosen = FakeWindow("chosen", log: log), broken = FakeWindow("broken", log: log), other = FakeWindow("other", log: log)
        broken.failure = Stub()
        application.all = [broken, other, chosen]

        do {
            try await noVSCode.apply([.direct(chosen)], in: application, columnsArea: area)
            XCTFail("expected a failure")
        } catch let error as WindowSwitchError {
            XCTAssertEqual(error.messages, ["stub failure"])
        }
        XCTAssertTrue(other.isMinimized)
    }

    func testAWindowThatCannotBeResizedStopsBeforeAnythingIsMinimized() async {
        let log = EventLog()
        let application = FakeApplication(log: log)
        let fixed = FakeWindow("fixed", log: log), second = FakeWindow("second", log: log), other = FakeWindow("other", log: log)
        fixed.failure = Stub()
        application.all = [fixed, second, other]

        do {
            try await noVSCode.apply([.direct(fixed), .direct(second)], in: application, columnsArea: area)
            XCTFail("expected a failure")
        } catch {}
        XCTAssertFalse(other.isMinimized)
    }

    func testVSCodeWindowsAreIdentifiedByTheFocusEachPathReceives() async throws {
        let log = EventLog()
        let application = FakeApplication(log: log)
        let alpha = FakeWindow("alpha", log: log), beta = FakeWindow("beta", log: log), other = FakeWindow("other", log: log)
        application.all = [other, alpha, beta]
        let alphaURL = "/p/alpha", betaURL = "/p/beta"
        let opener = ImmediateOpener()
        opener.onOpen = { application.focused = $0 == alphaURL ? alpha : beta }
        let locator = VSCodeWindowLocator(opener: opener, applicationURL: { URL(fileURLWithPath: "/Applications/Code.app") })
        let switcher = WindowSwitcher(locateVSCodeWindow: { try await locator.locate(path: $0, in: $1) })

        try await switcher.apply([.vscode(path: alphaURL), .vscode(path: betaURL)], in: application, columnsArea: area)

        XCTAssertEqual(opener.opened, [alphaURL, betaURL])
        XCTAssertEqual(alpha.frame?.minX, 0)
        XCTAssertEqual(beta.frame?.minX, 500)
        XCTAssertTrue(other.isMinimized)
        XCTAssertFalse(alpha.isMinimized)
    }

    func testFocusThatDoesNotMoveIsReportedAndMinimizesNothing() async {
        let log = EventLog()
        let application = FakeApplication(log: log)
        let stuck = FakeWindow("stuck", log: log), other = FakeWindow("other", log: log)
        application.all = [stuck, other]
        application.focused = stuck
        let locator = VSCodeWindowLocator(opener: ImmediateOpener(), applicationURL: { URL(fileURLWithPath: "/Applications/Code.app") })
        let switcher = WindowSwitcher(locateVSCodeWindow: { try await locator.locate(path: $0, in: $1) })

        do {
            try await switcher.apply([.vscode(path: "/p/a"), .vscode(path: "/p/b")],
                                     in: application, columnsArea: area)
            XCTFail("expected a failure")
        } catch let error as WindowSwitchError {
            XCTAssertEqual(error.messages, ["VS Code did not focus a separate window for /p/b."])
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertFalse(other.isMinimized)
    }

    private func locatorScenario() -> (VSCodeWindowLocator, ImmediateOpener, FakeApplication, FakeWindow) {
        let log = EventLog()
        let application = FakeApplication(log: log)
        let window = FakeWindow("a", log: log)
        application.all = [window]
        application.focused = window
        let opener = ImmediateOpener()
        let locator = VSCodeWindowLocator(opener: opener, applicationURL: { URL(fileURLWithPath: "/Applications/Code.app") })
        return (locator, opener, application, window)
    }

    func testAKnownWindowSkipsTheCommand() async throws {
        let (locator, opener, application, window) = locatorScenario()
        _ = try await locator.locate(path: "/p/a", in: application)
        let again = try await locator.locate(path: "/p/a", in: application)
        XCTAssertTrue(again === window)
        XCTAssertEqual(opener.opened, ["/p/a"])
    }

    func testAWindowNoLongerListedGoesBackToTheCommand() async throws {
        // A closed window, or one on another Space, where the command switches Space.
        let (locator, opener, application, window) = locatorScenario()
        _ = try await locator.locate(path: "/p/a", in: application)
        application.all = []
        let again = try await locator.locate(path: "/p/a", in: application)
        XCTAssertTrue(again === window)
        XCTAssertEqual(opener.opened, ["/p/a", "/p/a"])
    }

    func testPathsThatLeaveTheListAreForgotten() async throws {
        let (locator, opener, application, _) = locatorScenario()
        _ = try await locator.locate(path: "/p/a", in: application)
        locator.forgetPaths(notIn: ["/p/b"])
        _ = try await locator.locate(path: "/p/a", in: application)
        XCTAssertEqual(opener.opened, ["/p/a", "/p/a"])
    }

    func testAFullScreenWindowIsNotGivenAFrame() async throws {
        let log = EventLog()
        let application = FakeApplication(log: log)
        let full = FakeWindow("full", log: log), normal = FakeWindow("normal", log: log)
        full.isFullScreen = true
        application.all = [full, normal]
        try await noVSCode.apply([.direct(full), .direct(normal)], in: application, columnsArea: area)
        XCTAssertNil(full.frame)
        XCTAssertEqual(normal.frame, area)
    }

    func testAClosedWindowGoesBackToTheCommand() async throws {
        let (locator, opener, application, window) = locatorScenario()
        _ = try await locator.locate(path: "/p/a", in: application)
        window.exists = false
        _ = try await locator.locate(path: "/p/a", in: application)
        XCTAssertEqual(opener.opened, ["/p/a", "/p/a"])
    }

    func testAClosedWindowFreesItsPathForANewPair() async throws {
        // Regression: a reopened workspace could never pair again.
        let (locator, _, application, window) = locatorScenario()
        _ = try await locator.locate(path: "/p/a", in: application)
        XCTAssertTrue(locator.isKnown(path: "/p/a"))
        window.exists = false
        locator.forgetClosedWindows()
        XCTAssertFalse(locator.isKnown(path: "/p/a"))
    }

    func testLearnedWindowsSkipTheCommand() async throws {
        let (locator, opener, application, window) = locatorScenario()
        locator.correct([("/p/a", window)])
        XCTAssertTrue(locator.holds(path: "/p/a", window: window))
        let located = try await locator.locate(path: "/p/a", in: application)
        XCTAssertTrue(located === window)
        XCTAssertEqual(opener.opened, [])
    }

    func testAWindowBelongsToTheLastPathThatFocusedIt() async throws {
        // A window that opened another workspace must not answer for its old path.
        let (locator, opener, application, _) = locatorScenario()
        _ = try await locator.locate(path: "/p/old", in: application)
        _ = try await locator.locate(path: "/p/new", in: application)
        _ = try await locator.locate(path: "/p/old", in: application)
        XCTAssertEqual(opener.opened, ["/p/old", "/p/new", "/p/old"])
    }

    func testAFocusChangeBeforeTheCommandExitsIsNotTakenAsTheAnswer() async throws {
        // Regression: a window coming back from an earlier selection took focus while
        // the command ran, and was paired with the wrong path.
        let log = EventLog()
        let application = FakeApplication(log: log)
        let stray = FakeWindow("stray", log: log), target = FakeWindow("target", log: log)
        application.all = [stray, target]
        let opener = DeferredOpener()
        opener.onOpen = { application.focused = stray }
        opener.beforeFinishing = { application.focused = target }
        let locator = VSCodeWindowLocator(opener: opener, applicationURL: { URL(fileURLWithPath: "/Applications/Code.app") })

        let window = try await locator.locate(path: "/p/target", in: application)

        XCTAssertTrue(window === target)
    }

    func testAWindowStillComingBackIsNotTakenAsFocused() async throws {
        let log = EventLog()
        let application = FakeApplication(log: log)
        let target = FakeWindow("target", minimized: true, log: log)
        application.all = [target]
        application.focused = target
        let locator = VSCodeWindowLocator(opener: ImmediateOpener(), applicationURL: { URL(fileURLWithPath: "/Applications/Code.app") })
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            target.isMinimized = false
        }
        let window = try await locator.locate(path: "/p/target", in: application)
        XCTAssertTrue(window === target)
        XCTAssertFalse(window.isMinimized)
    }

    func testAnInactiveApplicationIsActivatedToReadItsFocus() async throws {
        let log = EventLog()
        let application = FakeApplication(log: log)
        let target = FakeWindow("target", log: log)
        application.all = [target]
        application.focusedOnlyWhenFrontmost = target
        let locator = VSCodeWindowLocator(opener: ImmediateOpener(), applicationURL: { URL(fileURLWithPath: "/Applications/Code.app") })
        let window = try await locator.locate(path: "/p/target", in: application)
        XCTAssertTrue(window === target)
        XCTAssertEqual(log.events, ["activate"])
    }

    func testAWindowThatArrivesLateIsMinimizedToo() async throws {
        // Regression: a window coming back from an earlier selection escaped the pass.
        let log = EventLog()
        let application = FakeApplication(log: log)
        let chosen = FakeWindow("chosen", log: log), late = FakeWindow("late", minimized: true, log: log)
        application.all = [chosen, late]
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            late.isMinimized = false
        }
        try await noVSCode.apply([.direct(chosen)], in: application, columnsArea: area)
        XCTAssertTrue(late.isMinimized)
    }

    func testMissingFocusAndCommandFailureAreReported() async {
        let log = EventLog()
        let application = FakeApplication(log: log)
        let opener = ImmediateOpener()
        let locator = VSCodeWindowLocator(opener: opener, applicationURL: { URL(fileURLWithPath: "/Applications/Code.app") })
        do {
            _ = try await locator.locate(path: "/p/a", in: application)
            XCTFail("expected a failure")
        } catch let error as WindowSwitchError {
            XCTAssertEqual(error.messages, ["VS Code reported no focused window for /p/a."])
        } catch {
            XCTFail("unexpected \(error)")
        }
        opener.failure = Stub()
        do {
            _ = try await locator.locate(path: "/p/a", in: application)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "stub failure")
        }
    }
}

@MainActor
final class WindowPanelControllerTests: XCTestCase {
    private func listed(_ name: String, _ titles: [String]) -> ListedApplication {
        let log = EventLog()
        return ListedApplication(
            name: name, icon: nil,
            windows: titles.map {
                ListedWindow(title: $0, toolTip: nil, isMinimized: false, selection: .direct(FakeWindow($0, log: log)))
            },
            problem: nil, application: FakeApplication(log: log))
    }

    private func makePanel() -> (WindowPanelController, () -> [(String, [String])]) {
        var applied: [(String, [String])] = []
        let panel = WindowPanelController(
            onApply: { application, windows in applied.append((application.name, windows.map(\.title))) },
            onRequestPermission: {}, onQuit: {})
        panel.reload(applications: [listed("Chrome", ["c1", "c2"]), listed("Code", ["a", "b", "c"])],
                     hasPermission: true, frontmostName: "Code")
        return (panel, { applied })
    }

    private func vscode(paths: [String], withoutPath: [String]) -> ListedApplication {
        let log = EventLog()
        let upper = paths.map { ListedWindow(title: $0, toolTip: nil, isMinimized: false, selection: .vscode(path: "/" + $0)) }
        let lower = withoutPath.map {
            ListedWindow(title: $0, toolTip: nil, isMinimized: false, selection: .direct(FakeWindow($0, log: log)), isWithoutPath: true)
        }
        return ListedApplication(name: "Code", icon: nil, windows: upper + lower, problem: nil, application: FakeApplication(log: log))
    }

    func testWindowsWithoutAPathArePartedByALineBelowTheOthers() {
        let panel = WindowPanelController(onApply: { _, _ in }, onRequestPermission: {}, onQuit: {})
        panel.reload(applications: [vscode(paths: ["a", "b"], withoutPath: ["Welcome"])], hasPermission: true, frontmostName: "Code")
        XCTAssertEqual(panel.windowsRowCountForTesting, 3)
        XCTAssertEqual(panel.separatedRowForTesting, 2)
    }

    func testBothKindsOfWindowHaveASectionHeadingEach() throws {
        let panel = WindowPanelController(onApply: { _, _ in }, onRequestPermission: {}, onQuit: {})
        panel.reload(applications: [vscode(paths: ["a", "b"], withoutPath: ["Welcome", "Other"])], hasPermission: true, frontmostName: "Code")
        XCTAssertEqual((0..<4).map { panel.sectionHeading(forRow: $0) },
                       [WindowPanelController.workspacesHeading, nil, WindowPanelController.otherWindowsHeading, nil])
        XCTAssertEqual(panel.windowsListHeightsForTesting().rows,
                       4 * WindowPanelController.rowHeight + 2 * WindowPanelController.sectionHeadingHeight + WindowPanelController.separatorHeight)
    }

    func testOneKindOfWindowHasNoHeading() {
        let panel = WindowPanelController(onApply: { _, _ in }, onRequestPermission: {}, onQuit: {})
        panel.reload(applications: [vscode(paths: ["a"], withoutPath: [])], hasPermission: true, frontmostName: "Code")
        XCTAssertNil(panel.sectionHeading(forRow: 0))
        panel.reload(applications: [vscode(paths: [], withoutPath: ["Welcome"])], hasPermission: true, frontmostName: "Code")
        XCTAssertNil(panel.sectionHeading(forRow: 0))
    }

    func testAClickOnAHeadingOrTheLineChoosesNothing() {
        let panel = WindowPanelController(onApply: { _, _ in }, onRequestPermission: {}, onQuit: {})
        panel.reload(applications: [vscode(paths: ["a", "b"], withoutPath: ["Welcome"])], hasPermission: true, frontmostName: "Code")
        let heading = WindowPanelController.sectionHeadingHeight
        let line = WindowPanelController.separatorHeight
        XCTAssertNil(panel.windowRow(clickedRow: 0, offsetFromRowTop: heading - 1))
        XCTAssertEqual(panel.windowRow(clickedRow: 0, offsetFromRowTop: heading + 1), 0)
        XCTAssertEqual(panel.windowRow(clickedRow: 1, offsetFromRowTop: 0), 1)
        XCTAssertNil(panel.windowRow(clickedRow: 2, offsetFromRowTop: line + heading - 1))
        XCTAssertEqual(panel.windowRow(clickedRow: 2, offsetFromRowTop: line + heading + 1), 2)
        XCTAssertNil(panel.windowRow(clickedRow: -1, offsetFromRowTop: 5))
    }

    func testNoLineWithoutBothKindsOfWindow() {
        let panel = WindowPanelController(onApply: { _, _ in }, onRequestPermission: {}, onQuit: {})
        panel.reload(applications: [vscode(paths: ["a"], withoutPath: [])], hasPermission: true, frontmostName: "Code")
        XCTAssertNil(panel.separatedRowForTesting)
        panel.reload(applications: [vscode(paths: [], withoutPath: ["Welcome"])], hasPermission: true, frontmostName: "Code")
        XCTAssertNil(panel.separatedRowForTesting)
        panel.reload(applications: [listed("Chrome", ["c1", "c2"])], hasPermission: true, frontmostName: "Chrome")
        XCTAssertNil(panel.separatedRowForTesting)
    }

    func testClickingAWindowWithoutAPathAppliesThatRow() {
        var applied: [String] = []
        let panel = WindowPanelController(onApply: { _, windows in applied = windows.map(\.title) }, onRequestPermission: {}, onQuit: {})
        panel.reload(applications: [vscode(paths: ["a", "b"], withoutPath: ["Welcome"])], hasPermission: true, frontmostName: "Code")
        panel.clickWindow(row: 2, shift: false)
        XCTAssertEqual(applied, ["Welcome"])
    }

    func testASelectionIsDroppedWhenAWindowMovesBetweenTheParts() {
        let panel = WindowPanelController(onApply: { _, _ in }, onRequestPermission: {}, onQuit: {})
        panel.reload(applications: [vscode(paths: ["a", "b"], withoutPath: ["Welcome"])], hasPermission: true, frontmostName: "Code")
        panel.clickWindow(row: 2, shift: true)
        panel.update(applications: [vscode(paths: ["a", "b", "c"], withoutPath: [])])
        XCTAssertEqual(panel.selection.rows, [], "the same row is now another window")
    }

    func testTheRequestForPermissionGoesWhenPermissionArrives() {
        let (panel, _) = makePanel()
        panel.setHasPermission(false)
        XCTAssertTrue(panel.isAskingForPermissionForTesting)
        panel.setHasPermission(true)
        XCTAssertFalse(panel.isAskingForPermissionForTesting)
    }

    func testAnApplicationThatDoesNotAnswerKeepsItsRows() {
        let word = listed("Word", ["doc1", "doc2"])
        let list = WindowListing.merged([.noAnswer(identifier: word.identifier)], previous: [word])
        XCTAssertEqual(list.map(\.name), ["Word"])
        XCTAssertEqual(list.first?.windows.map(\.title), ["doc1", "doc2"])
    }

    func testAnApplicationStillBeingReadKeepsItsRows() {
        let word = listed("Word", ["doc"])
        XCTAssertEqual(WindowListing.merged([.waiting(identifier: word.identifier)], previous: [word]).map(\.name), ["Word"])
    }

    func testAnApplicationThatAnswersIsReplaced() {
        let list = WindowListing.merged([.answered(listed("Word", ["new"]))], previous: [listed("Word", ["old"])])
        XCTAssertEqual(list.first?.windows.map(\.title), ["new"])
    }

    func testAnApplicationThatSaysItHasNoWindowsGoes() {
        XCTAssertTrue(WindowListing.merged([.answered(nil)], previous: [listed("Word", ["old"])]).isEmpty)
    }

    func testAnApplicationThatHasQuitGoes() {
        XCTAssertTrue(WindowListing.merged([], previous: [listed("Word", ["old"])]).isEmpty, "only running applications are read")
    }

    func testAnApplicationNeverReadIsNotInventedWhileItDoesNotAnswer() {
        XCTAssertTrue(WindowListing.merged([.noAnswer(identifier: "Word")], previous: []).isEmpty)
    }

    func testHeightFollowsTheContentUpToTheAvailableSpace() {
        XCTAssertEqual(WindowPanelController.panelHeight(contentHeight: 600, available: 1000), 600)
        XCTAssertEqual(WindowPanelController.panelHeight(contentHeight: 1500, available: 1000), 1000)
        XCTAssertEqual(WindowPanelController.panelHeight(contentHeight: 50, available: 1000), 50)
    }

    private func shownPanel(windowCount: Int) throws -> (WindowPanelController, NSRect) {
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = screen.visibleFrame
        let panel = WindowPanelController(onApply: { _, _ in }, onRequestPermission: {}, onQuit: {})
        let titles = (0..<windowCount).map { "w\($0)" }
        panel.show(applications: [listed("Many", titles)], hasPermission: true, frontmostName: "Many",
                   below: NSRect(x: visible.midX, y: visible.maxY, width: 30, height: 20))
        return (panel, visible)
    }

    func testEveryRowIsVisibleWithoutScrollingWhenTheScreenIsTallEnough() throws {
        let (panel, visible) = try shownPanel(windowCount: 20)
        defer { panel.close() }
        let heights = panel.windowsListHeightsForTesting()
        XCTAssertEqual(heights.rows, 480)
        XCTAssertGreaterThanOrEqual(heights.visible, heights.rows)
        XCTAssertEqual(panel.panelFrameForTesting.maxY, visible.maxY)
    }

    func testPanelStaysOnScreenWhenTheListIsLongerThanTheScreen() throws {
        let (panel, visible) = try shownPanel(windowCount: 200)
        defer { panel.close() }
        XCTAssertEqual(panel.panelFrameForTesting.height, visible.height)
        XCTAssertEqual(panel.panelFrameForTesting.minY, visible.minY)
    }

    private func shownPanel(_ applications: [ListedApplication], frontmost: String) throws -> (WindowPanelController, NSRect) {
        let visible = try XCTUnwrap(NSScreen.main).visibleFrame
        let panel = WindowPanelController(onApply: { _, _ in }, onRequestPermission: {}, onQuit: {})
        panel.show(applications: applications, hasPermission: true, frontmostName: frontmost,
                   below: NSRect(x: visible.midX, y: visible.maxY, width: 30, height: 20))
        return (panel, visible)
    }

    func testHeightFollowsTheChosenApplicationAndTheTopStaysPut() throws {
        let long = (0..<15).map { "w\($0)" }
        let (panel, visible) = try shownPanel(
            [listed("A", ["a"]), listed("B", long), listed("C", ["c1", "c2", "c3"]), listed("D", ["d"])], frontmost: "A")
        defer { panel.close() }
        let short = panel.panelFrameForTesting.height
        panel.chooseApplication(1)
        let tall = panel.panelFrameForTesting
        XCTAssertEqual(tall.height - short, 11 * WindowPanelController.rowHeight, "15 rows against the 4 applications")
        XCTAssertEqual(tall.maxY, visible.maxY)
        let heights = panel.windowsListHeightsForTesting()
        XCTAssertGreaterThanOrEqual(heights.visible, heights.rows)
        panel.chooseApplication(2)
        XCTAssertEqual(panel.panelFrameForTesting.height, short, "3 rows are fewer than the 4 applications")
        XCTAssertEqual(panel.panelFrameForTesting.maxY, visible.maxY)
    }

    func testHeightFollowsAnUpdateAndAnApplicationThatQuit() throws {
        let a = listed("A", ["a"]), b = listed("B", ["b"]), c = listed("C", ["c"])
        let (panel, _) = try shownPanel([a, b, c], frontmost: "A")
        defer { panel.close() }
        let before = panel.panelFrameForTesting.height
        panel.update(applications: [a, b])
        XCTAssertEqual(panel.panelFrameForTesting.height, before - WindowPanelController.rowHeight)
    }

    func testChoosingAnApplicationThatDoesNotFitStaysOnScreenAndScrolls() throws {
        let (panel, visible) = try shownPanel(
            [listed("A", ["a"]), listed("B", (0..<200).map { "w\($0)" })], frontmost: "A")
        defer { panel.close() }
        panel.chooseApplication(1)
        XCTAssertEqual(panel.panelFrameForTesting.height, visible.height)
        XCTAssertEqual(panel.panelFrameForTesting.minY, visible.minY)
        let heights = panel.windowsListHeightsForTesting()
        XCTAssertLessThan(heights.visible, heights.rows)
    }

    func testAProblemMessageDoesNotTakeRoomFromTheRows() throws {
        let log = EventLog()
        let problem = String(repeating: "Cannot read the windows of this application. ", count: 8)
        let failing = ListedApplication(name: "F", icon: nil, windows: [], problem: problem, application: FakeApplication(log: log))
        let (panel, _) = try shownPanel([failing, listed("B", ["b"]), listed("C", ["c"])], frontmost: "F")
        defer { panel.close() }
        let area = panel.applicationsListHeightForTesting()
        XCTAssertGreaterThanOrEqual(area, 3 * WindowPanelController.rowHeight)
    }

    func testOpensOnTheFrontmostApplication() {
        let (panel, _) = makePanel()
        XCTAssertEqual(panel.selectedApplication, 1)
        XCTAssertEqual(panel.windowsRowCountForTesting, 3)
    }

    func testAnApplicationJustStartedIsChosenWhenTheUpdateBringsIt() {
        let panel = WindowPanelController(onApply: { _, _ in }, onRequestPermission: {}, onQuit: {})
        let old = listed("Old", ["o"]), new = listed("New", ["n"])
        panel.reload(applications: [old], hasPermission: true, frontmostName: "New")
        XCTAssertEqual(panel.applications[panel.selectedApplication ?? -1].name, "Old")
        panel.update(applications: [new, old])
        XCTAssertEqual(panel.applications[panel.selectedApplication ?? -1].name, "New")
    }

    func testAnUpdateDoesNotUndoTheUsersChoice() {
        let panel = WindowPanelController(onApply: { _, _ in }, onRequestPermission: {}, onQuit: {})
        let a = listed("A", ["a"]), b = listed("B", ["b"]), c = listed("C", ["c"])
        panel.reload(applications: [a, b], hasPermission: true, frontmostName: "C")
        panel.selectApplicationRowForTesting(1)
        panel.update(applications: [a, b, c])
        XCTAssertEqual(panel.applications[panel.selectedApplication ?? -1].name, "B")
    }

    func testAfterQuittingTheNextUpdateDoesNotJumpBackToTheFrontmost() {
        let panel = WindowPanelController(onApply: { _, _ in }, onRequestPermission: {}, onQuit: {})
        let a = listed("A", ["a"]), b = listed("B", ["b"]), c = listed("C", ["c"])
        panel.reload(applications: [a, b, c], hasPermission: true, frontmostName: "A")
        panel.selectApplicationRowForTesting(1)
        panel.quitChosenApplication()
        panel.update(applications: [a, c])
        XCTAssertEqual(panel.applications[panel.selectedApplication ?? -1].name, "C")
    }

    func testPlainClickAppliesThatWindowAlone() {
        let (panel, applied) = makePanel()
        panel.clickWindow(row: 1, shift: false)
        XCTAssertEqual(applied().map(\.0), ["Code"])
        XCTAssertEqual(applied().first?.1, ["b"])
    }

    func testShiftClicksApplyInClickOrderWhenShiftIsReleased() {
        let (panel, applied) = makePanel()
        panel.clickWindow(row: 2, shift: true)
        panel.clickWindow(row: 0, shift: true)
        XCTAssertTrue(applied().isEmpty)
        XCTAssertEqual(panel.selection.order(of: 2), 1)
        XCTAssertEqual(panel.selection.order(of: 0), 2)

        panel.shiftReleased()
        XCTAssertEqual(applied().first?.1, ["c", "a"])
        XCTAssertEqual(panel.selection.rows, [])
    }

    func testShiftClickingTwiceDeselects() {
        let (panel, applied) = makePanel()
        panel.clickWindow(row: 1, shift: true)
        panel.clickWindow(row: 1, shift: true)
        panel.shiftReleased()
        XCTAssertTrue(applied().isEmpty)
    }

    func testChoosingAnotherApplicationClearsTheSelection() {
        let (panel, applied) = makePanel()
        panel.clickWindow(row: 0, shift: true)
        panel.chooseApplication(0)
        XCTAssertEqual(panel.selection.rows, [])
        panel.shiftReleased()
        XCTAssertTrue(applied().isEmpty)
        XCTAssertEqual(panel.windowsRowCountForTesting, 2)
    }

    func testAnUpdateKeepsTheChosenApplicationAndSelection() {
        let (panel, _) = makePanel()
        panel.clickWindow(row: 2, shift: true)
        panel.update(applications: [listed("New", ["n"]), listed("Chrome", ["c1", "c2"]), listed("Code", ["a", "b", "c"])])
        XCTAssertEqual(panel.applications[panel.selectedApplication ?? -1].name, "Code")
        XCTAssertEqual(panel.selection.rows, [2])
    }

    func testAnUpdateThatChangesTheWindowsClearsTheSelection() {
        // The rows now mean other windows, so keeping them would pick the wrong ones.
        let (panel, _) = makePanel()
        panel.clickWindow(row: 2, shift: true)
        panel.update(applications: [listed("Code", ["a", "b"])])
        XCTAssertEqual(panel.selection.rows, [])
    }

    func testAnUpdateFallsBackWhenTheApplicationHasQuit() {
        let (panel, _) = makePanel()
        panel.update(applications: [listed("Chrome", ["c1"])])
        XCTAssertEqual(panel.selectedApplication, 0)
        panel.update(applications: [])
        XCTAssertNil(panel.selectedApplication)
    }

    func testQuittingAsksOnlyTheChosenApplicationAndKeepsThePanelsChoice() throws {
        let (panel, _) = makePanel()
        panel.quitChosenApplication()
        let chrome = try XCTUnwrap(panel.applications[0].application as? FakeApplication)
        let code = try XCTUnwrap(panel.applications[1].application as? FakeApplication)
        XCTAssertEqual(chrome.terminateRequests, 0)
        XCTAssertEqual(code.terminateRequests, 1)
        XCTAssertEqual(panel.selectedApplication, 1)
    }

    func testQuittingWithNothingChosenAsksNobody() throws {
        let (panel, _) = makePanel()
        panel.chooseApplication(nil)
        panel.quitChosenApplication()
        for application in panel.applications {
            XCTAssertEqual(try XCTUnwrap(application.application as? FakeApplication).terminateRequests, 0)
        }
    }

    func testTheNextApplicationTakesTheRowOfOneThatQuit() {
        let panel = WindowPanelController(onApply: { _, _ in }, onRequestPermission: {}, onQuit: {})
        let a = listed("A", ["a"]), b = listed("B", ["b"]), c = listed("C", ["c"])
        panel.reload(applications: [a, b, c], hasPermission: true, frontmostName: "B")
        panel.update(applications: [a, c])
        XCTAssertEqual(panel.selectedApplication, 1)
        XCTAssertEqual(panel.applications[1].name, "C")
        panel.update(applications: [a])
        XCTAssertEqual(panel.selectedApplication, 0)
        panel.update(applications: [])
        XCTAssertNil(panel.selectedApplication)
    }

    func testChosenRowsShowTheirOrderAndOthersKeepAnEmptyPlace() throws {
        let (panel, _) = makePanel()
        panel.clickWindow(row: 2, shift: true)
        panel.clickWindow(row: 0, shift: true)
        XCTAssertEqual(try XCTUnwrap(panel.orderBadgeForTesting(row: 2)).number, 1)
        XCTAssertEqual(try XCTUnwrap(panel.orderBadgeForTesting(row: 0)).number, 2)
        XCTAssertNil(try XCTUnwrap(panel.orderBadgeForTesting(row: 1)).number)

        panel.clickWindow(row: 2, shift: true)
        XCTAssertNil(try XCTUnwrap(panel.orderBadgeForTesting(row: 2)).number)
        XCTAssertEqual(try XCTUnwrap(panel.orderBadgeForTesting(row: 0)).number, 1, "the later choice moves up")
    }

    func testChoosingAnotherApplicationClearsTheBadges() throws {
        let (panel, _) = makePanel()
        panel.clickWindow(row: 0, shift: true)
        panel.chooseApplication(0)
        XCTAssertNil(try XCTUnwrap(panel.orderBadgeForTesting(row: 0)).number)
    }

    private func pinsInFreshDefaults() throws -> (PinnedApplications, UserDefaults, () -> Void) {
        let suite = "com.tranworks.switch.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (PinnedApplications(defaults: defaults), defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    private func panel(pins: PinnedApplications) -> WindowPanelController {
        let panel = WindowPanelController(onApply: { _, _ in }, onRequestPermission: {}, onQuit: {}, pins: pins)
        panel.reload(applications: [listed("Alpha", ["a"]), listed("Beta", ["b1", "b2"]), listed("Gamma", ["g"])],
                     hasPermission: true, frontmostName: "Beta")
        return panel
    }

    func testPinningMovesAnApplicationToTheTopAndKeepsTheOthersInOrder() throws {
        let (pins, _, cleanup) = try pinsInFreshDefaults()
        defer { cleanup() }
        let panel = panel(pins: pins)
        XCTAssertEqual(panel.applications.map(\.name), ["Alpha", "Beta", "Gamma"])
        panel.togglePin(row: 2)
        XCTAssertEqual(panel.applications.map(\.name), ["Gamma", "Alpha", "Beta"])
        panel.togglePin(row: 2)
        XCTAssertEqual(panel.applications.map(\.name), ["Beta", "Gamma", "Alpha"])
    }

    func testUnpinningReturnsAnApplicationToItsPlace() throws {
        let (pins, _, cleanup) = try pinsInFreshDefaults()
        defer { cleanup() }
        let panel = panel(pins: pins)
        panel.togglePin(row: 2)
        panel.togglePin(row: 0)
        XCTAssertEqual(panel.applications.map(\.name), ["Alpha", "Beta", "Gamma"])
    }

    func testPinningKeepsTheChosenApplicationAndSelection() throws {
        let (pins, _, cleanup) = try pinsInFreshDefaults()
        defer { cleanup() }
        let panel = panel(pins: pins)
        panel.clickWindow(row: 1, shift: true)
        panel.togglePin(row: 2)
        XCTAssertEqual(panel.applications[panel.selectedApplication ?? -1].name, "Beta")
        XCTAssertEqual(panel.selection.rows, [1])
    }

    func testPinsLastAcrossLaunches() throws {
        let (pins, defaults, cleanup) = try pinsInFreshDefaults()
        defer { cleanup() }
        pins.toggle("com.example.gamma")
        XCTAssertTrue(PinnedApplications(defaults: defaults).contains("com.example.gamma"))
        pins.toggle("com.example.gamma")
        XCTAssertFalse(PinnedApplications(defaults: defaults).contains("com.example.gamma"))
    }

    func testAPinFollowsTheBundleIdentifierAndNotTheName() {
        let log = EventLog()
        let application = ListedApplication(name: "Name", icon: nil, windows: [], problem: nil,
                                            application: FakeApplication(log: log), bundleIdentifier: "com.example.app")
        XCTAssertEqual(application.identifier, "com.example.app")
    }

    func testReleasingShiftWithNothingSelectedDoesNothing() {
        let (panel, applied) = makePanel()
        panel.shiftReleased()
        XCTAssertTrue(applied().isEmpty)
    }
}

@MainActor
final class WindowPinTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "com.tranworks.switch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    private func application(_ rows: [ListedWindow]) -> ListedApplication {
        ListedApplication(name: "App", icon: nil, windows: rows, problem: nil,
                          application: FakeApplication(log: EventLog()), bundleIdentifier: "app")
    }

    private func terminal(_ id: Int, _ group: String) -> ListedWindow {
        ListedWindow(title: "t\(id)", toolTip: nil, isMinimized: false,
                     selection: .ptermTerminal(id: "\(id)"), group: group)
    }

    private func direct(_ title: String) -> ListedWindow {
        ListedWindow(title: title, toolTip: nil, isMinimized: false, selection: .direct(FakeWindow(title, log: EventLog())))
    }

    func testPinnedWindowComesFirstAndGoesBackWhenUnpinned() {
        let pins = PinnedApplications(defaults: defaults())
        let list = application([direct("a"), direct("b"), direct("c")])
        pins.toggleWindow("c", of: "app")
        XCTAssertEqual(pins.ordered([list])[0].windows.map(\.title), ["c", "a", "b"])
        pins.toggleWindow("c", of: "app")
        XCTAssertEqual(pins.ordered([list])[0].windows.map(\.title), ["a", "b", "c"])
    }

    func testPinsLastAndBelongToTheirApplication() {
        let stored = defaults()
        PinnedApplications(defaults: stored).toggleWindow("c", of: "app")
        let later = PinnedApplications(defaults: stored)
        XCTAssertTrue(later.containsWindow("c", of: "app"))
        XCTAssertFalse(later.containsWindow("c", of: "other"))
    }

    func testPinStaysInsideItsWorkspace() {
        let pins = PinnedApplications(defaults: defaults())
        let list = application([terminal(1, "A"), terminal(2, "A"), terminal(3, "B"), terminal(4, "B")])
        pins.toggleWindow("4", of: "app")
        XCTAssertEqual(pins.ordered([list])[0].windows.map(\.title), ["t1", "t2", "t4", "t3"])
    }

    func testPinIsOnTheTerminalNotItsTitle() {
        let pins = PinnedApplications(defaults: defaults())
        pins.toggleWindow("2", of: "app")
        let list = application([
            ListedWindow(title: "same", toolTip: nil, isMinimized: false, selection: .ptermTerminal(id: "1"), group: "A"),
            ListedWindow(title: "same", toolTip: nil, isMinimized: false, selection: .ptermTerminal(id: "2"), group: "A")])
        XCTAssertEqual(pins.ordered([list])[0].windows.map(\.pinKey), ["2", "1"])
    }

    func testPanelMovesThePinnedRowAndKeepsTheShiftSelection() {
        var applied: [String] = []
        let panel = WindowPanelController(onApply: { _, rows in applied = rows.map(\.title) }, onRequestPermission: {}, onQuit: {},
                                          pins: PinnedApplications(defaults: defaults()))
        panel.reload(applications: [application([direct("a"), direct("b"), direct("c")])], hasPermission: true, frontmostName: "App")
        panel.clickWindow(row: 1, shift: true)
        panel.toggleWindowPin(row: 2)
        XCTAssertEqual(panel.applications[0].windows.map(\.title), ["c", "a", "b"])
        XCTAssertEqual(panel.selection.rows, [2])
        panel.toggleWindowPin(row: 0)
        XCTAssertEqual(panel.applications[0].windows.map(\.title), ["a", "b", "c"])
        XCTAssertEqual(panel.selection.rows, [1])
        panel.shiftReleased()
        XCTAssertEqual(applied, ["b"])
    }

    func testAReadingKeepsThePinnedOrder() {
        let panel = WindowPanelController(onApply: { _, _ in }, onRequestPermission: {}, onQuit: {},
                                          pins: PinnedApplications(defaults: defaults()))
        let rows = [direct("a"), direct("b")]
        panel.reload(applications: [application(rows)], hasPermission: true, frontmostName: "App")
        panel.toggleWindowPin(row: 1)
        panel.update(applications: [application(rows)])
        XCTAssertEqual(panel.applications[0].windows.map(\.title), ["b", "a"])
    }

    func testEachWorkspaceHasItsHeadingAndALineBetween() {
        let panel = WindowPanelController(onApply: { _, _ in }, onRequestPermission: {}, onQuit: {},
                                          pins: PinnedApplications(defaults: defaults()))
        panel.reload(applications: [application([terminal(1, "A"), terminal(2, "A"), terminal(3, "B")])],
                     hasPermission: true, frontmostName: "App")
        XCTAssertEqual((0..<3).map { panel.sectionHeading(forRow: $0) }, ["A", nil, "B"])
        XCTAssertEqual(panel.windowsListHeightsForTesting().rows,
                       3 * WindowPanelController.rowHeight + 2 * WindowPanelController.sectionHeadingHeight + WindowPanelController.separatorHeight)
        XCTAssertNil(panel.windowRow(clickedRow: 2, offsetFromRowTop: 1))
    }
}

final class PtermSelectionTests: XCTestCase {
    func testTerminalsAreOneRequestAndTheirWindowIsTreatedAsASingleWindow() async throws {
        let log = EventLog()
        let window = FakeWindow("pterm", log: log)
        let settings = FakeWindow("settings", log: log)
        let application = FakeApplication(log: log)
        application.all = [window, settings]
        var asked: [[String]] = []
        var switcher = WindowSwitcher(locateVSCodeWindow: { _, _ in throw WindowSwitchError(messages: ["unused"]) })
        switcher.showPtermTerminals = { terminals, _ in
            asked.append(terminals)
            return window
        }
        let area = CGRect(x: 0, y: 25, width: 1000, height: 700)
        try await switcher.apply([.ptermTerminal(id: "a"), .ptermTerminal(id: "b")], in: application, columnsArea: area)
        XCTAssertEqual(asked, [["a", "b"]])
        // Whatever pterm does inside it, the window fills the area alone.
        XCTAssertEqual(window.frame, area)
        XCTAssertTrue(settings.isMinimized)
    }

    func testRefusedShowMovesNothing() async {
        let log = EventLog()
        let window = FakeWindow("pterm", log: log)
        let application = FakeApplication(log: log)
        application.all = [window]
        var switcher = WindowSwitcher(locateVSCodeWindow: { _, _ in throw WindowSwitchError(messages: ["unused"]) })
        switcher.showPtermTerminals = { _, _ in throw WindowSwitchError(messages: ["gone"]) }
        do {
            try await switcher.apply([.ptermTerminal(id: "a")], in: application, columnsArea: .zero)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? WindowSwitchError, WindowSwitchError(messages: ["gone"]))
        }
        XCTAssertNil(window.frame)
    }

    func testATerminalNotOnShowReadsAsMinimized() {
        let rows = WindowListing.ptermRows([
            .init(id: "1", title: "shown", workspace: "A", isDisplayed: true),
            .init(id: "2", title: "behind", workspace: "A", isDisplayed: false)])
        XCTAssertEqual(rows.map(\.isMinimized), [false, true])
        XCTAssertEqual(rows.map(\.group), ["A", "A"])
    }
}

final class PtermBridgeClientTests: XCTestCase {
    private let one = "11111111-1111-1111-1111-111111111111"

    /// A stand-in for pterm: answers one connection with these bytes.
    private func serving(_ reply: Data?, verified: Bool = true,
                         _ body: (PtermBridgeClient) throws -> Void) throws {
        let path = "/tmp/psc-\(UUID().uuidString.prefix(8)).sock"
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        defer { close(listener); unlink(path) }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let connection = accept(listener, nil, nil)
            defer { if connection >= 0 { close(connection) }; done.signal() }
            guard connection >= 0 else { return }
            var noSignal: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = read(connection, &buffer, buffer.count)
            if let reply { _ = reply.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) } }
        }
        try body(PtermBridgeClient(socketPath: path, verifyPeer: { _ in verified }))
        shutdown(listener, SHUT_RDWR)
        done.wait()
    }

    private func line(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object) + Data("\n".utf8)
    }

    func testListReadsTerminals() throws {
        let reply = try line(["ok": true, "window_number": 5, "terminals": [
            ["id": one, "title": "logs", "workspace": "A", "displayed": true]]])
        try serving(reply) { client in
            XCTAssertEqual(try client.list(), [.init(id: one, title: "logs", workspace: "A", isDisplayed: true)])
        }
    }

    func testEntriesThatAreNotWhatWasPromisedAreDropped() throws {
        let reply = try line(["ok": true, "terminals": [
            ["id": "../../etc/passwd", "title": "x", "workspace": "A", "displayed": true],
            ["id": one, "title": 7, "workspace": "A", "displayed": true],
            ["id": one, "title": "ok", "workspace": "A", "displayed": false]]])
        try serving(reply) { client in
            XCTAssertEqual(try client.list().map(\.title), ["ok"])
        }
    }

    func testAPeerThatIsNotPtermIsToldNothingAndNotBelieved() throws {
        let reply = try line(["ok": true, "terminals": [["id": one, "title": "fake", "workspace": "A", "displayed": true]]])
        try serving(reply, verified: false) { client in
            XCTAssertThrowsError(try client.list()) { XCTAssertEqual($0 as? PtermBridgeClient.Failure, .unavailable) }
        }
    }

    func testNoSocketMeansNoBridge() {
        let client = PtermBridgeClient(socketPath: "/tmp/psc-none-\(UUID().uuidString.prefix(8))", verifyPeer: { _ in true })
        XCTAssertThrowsError(try client.list()) { XCTAssertEqual($0 as? PtermBridgeClient.Failure, .unavailable) }
    }

    func testSymlinkInPlaceOfTheSocketIsNotFollowed() throws {
        let path = "/tmp/psc-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "/tmp")
        defer { unlink(path) }
        let client = PtermBridgeClient(socketPath: path, verifyPeer: { _ in true })
        XCTAssertThrowsError(try client.list()) { XCTAssertEqual($0 as? PtermBridgeClient.Failure, .unavailable) }
    }

    func testRefusalIsNotMistakenForNoBridge() throws {
        try serving(try line(["ok": false, "error": "unknown terminal"])) { client in
            XCTAssertThrowsError(try client.show(terminals: [one])) { XCTAssertEqual($0 as? PtermBridgeClient.Failure, .refused) }
        }
    }

    func testShowSendsOnlyRealIdentifiers() throws {
        let client = PtermBridgeClient(socketPath: "/nonexistent", verifyPeer: { _ in true })
        XCTAssertThrowsError(try client.show(terminals: ["\"},{\"op\":\"x"])) { XCTAssertEqual($0 as? PtermBridgeClient.Failure, .refused) }
        XCTAssertThrowsError(try client.show(terminals: [])) { XCTAssertEqual($0 as? PtermBridgeClient.Failure, .refused) }
    }

    func testTitlesAreOnlyEverTextToShow() {
        XCTAssertEqual(PtermBridgeClient.displayText("a\u{1B}[31mb\nc\u{7}"), "a[31mbc")
        // A right-to-left override can make a name read as something else.
        XCTAssertEqual(PtermBridgeClient.displayText("doc\u{202E}gpj.exe"), "docgpj.exe")
        XCTAssertEqual(PtermBridgeClient.displayText("日本語 プロジェクト"), "日本語 プロジェクト")
        XCTAssertEqual(PtermBridgeClient.displayText(String(repeating: "x", count: 500)).count, 201)
    }

    func testRequirementNamesDeveloperIDTeamAndPterm() {
        let text = PtermPeerVerifier.requirementText(team: "ABCDE12345")
        XCTAssertTrue(text.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
        XCTAssertTrue(text.contains("identifier \"com.tranworks.pterm\""))
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess)
        XCTAssertFalse(PtermPeerVerifier.isPlainTeamIdentifier("A\" or anchor apple or \"B"))
    }
}

final class FrontWindowTests: XCTestCase {
    private func row(_ title: String, minimized: Bool = false) -> ListedWindow {
        ListedWindow(title: title, toolTip: nil, isMinimized: minimized, selection: .vscode(path: title))
    }

    private let numbers = ["a": 10, "b": 20, "c": 30]

    func testTheFirstListedWindowFromTheFrontIsTheOne() {
        let onScreen: [FrontWindow.OnScreen] = [.init(processIdentifier: 9, number: 99),
                                                .init(processIdentifier: 1, number: 20),
                                                .init(processIdentifier: 1, number: 10)]
        let marked = FrontWindow.marked([row("a"), row("b")], of: 1, in: onScreen) { self.numbers[$0.title] }
        XCTAssertEqual(marked.map(\.isFrontmost), [false, true])
    }

    func testAPaletteOfTheSameApplicationIsNotTheAnswer() {
        let onScreen: [FrontWindow.OnScreen] = [.init(processIdentifier: 1, number: 500),
                                                .init(processIdentifier: 1, number: 10)]
        let marked = FrontWindow.marked([row("a"), row("b")], of: 1, in: onScreen) { self.numbers[$0.title] }
        XCTAssertEqual(marked.map(\.isFrontmost), [true, false])
    }

    func testAnotherApplicationsWindowWithThatNumberDoesNotCount() {
        XCTAssertNil(FrontWindow.number(among: [10], of: 1, in: [.init(processIdentifier: 2, number: 10)]))
    }

    func testNothingOnScreenMarksNothing() {
        let marked = FrontWindow.marked([row("a"), row("b")], of: 1, in: []) { self.numbers[$0.title] }
        XCTAssertEqual(marked.map(\.isFrontmost), [false, false])
    }

    func testAWindowWhoseNumberIsUnknownIsNeverMarked() {
        let marked = FrontWindow.marked([row("a"), row("unknown")], of: 1, in: [.init(processIdentifier: 1, number: 10)]) { self.numbers[$0.title] }
        XCTAssertEqual(marked.map(\.isFrontmost), [true, false])
    }

    func testEveryTerminalOnShowInPtermIsMarked() {
        let rows = WindowListing.ptermRows([
            .init(id: "1", title: "a", workspace: "A", isDisplayed: true),
            .init(id: "2", title: "b", workspace: "A", isDisplayed: true),
            .init(id: "3", title: "c", workspace: "A", isDisplayed: false)])
        XCTAssertEqual(rows.map(\.isFrontmost), [true, true, false])
    }

    @MainActor
    func testTheFrontRowHasItsOwnColor() {
        var front = row("a")
        front.isFrontmost = true
        let plain = WindowPanelController.windowTextColor(row("b"))
        let minimized = WindowPanelController.windowTextColor(row("c", minimized: true))
        let color = WindowPanelController.windowTextColor(front)
        XCTAssertNotEqual(color, plain)
        XCTAssertNotEqual(color, minimized)
        func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor? {
            var result: NSColor?
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                result = color.usingColorSpace(.sRGB)
            }
            return result
        }
        // Darker than the accent color on light glass, where it is too bright to read, and still that hue.
        let accent = resolved(.controlAccentColor, .aqua)
        let darker = resolved(color, .aqua)
        XCTAssertLessThan(darker?.brightnessComponent ?? 1, (accent?.brightnessComponent ?? 0) * 0.7)
        XCTAssertEqual(darker?.hueComponent ?? 0, accent?.hueComponent ?? 1, accuracy: 0.03)
        let accentDark = resolved(.controlAccentColor, .darkAqua)
        XCTAssertEqual(resolved(color, .darkAqua)?.blueComponent ?? 0, accentDark?.blueComponent ?? 0, accuracy: 0.01)
    }
}
