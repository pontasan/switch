import AppKit
import XCTest
@testable import SwitchApp

final class WindowShortcutParseTests: XCTestCase {
    private func entry(enabled: Any = true, parameters: [Any] = [65535, 48, 524288]) -> [String: Any] {
        ["27": ["enabled": enabled, "value": ["parameters": parameters, "type": "standard"]]]
    }

    func testReadsTheKeyAndModifiersFromTheSettings() {
        XCTAssertEqual(WindowShortcut.parse(entry()),
                       WindowShortcut(keyCode: 48, modifiers: CGEventFlags.maskAlternate.rawValue))
    }

    func testANumberStoredAsOneIsAlsoOn() {
        XCTAssertNotNil(WindowShortcut.parse(entry(enabled: NSNumber(value: 1))))
    }

    func testAShortcutThatIsTurnedOffIsNotDetected() {
        XCTAssertNil(WindowShortcut.parse(entry(enabled: false)))
    }

    func testAShortcutThatWasNeverChangedIsTheStandardOne() {
        XCTAssertEqual(WindowShortcut.parse(["1": [:]]), .standard)
        XCTAssertEqual(WindowShortcut.parse(nil), .standard)
        XCTAssertEqual(WindowShortcut.standard, WindowShortcut(keyCode: 50, modifiers: CGEventFlags.maskCommand.rawValue))
    }

    func testAShortcutWithoutAModifierHasNothingToRelease() {
        XCTAssertNil(WindowShortcut.parse(entry(parameters: [65535, 122, 0])))
        XCTAssertNil(WindowShortcut.parse(entry(parameters: [65535, 122, 8388608])), "the Fn bit alone is not a modifier to hold")
    }

    func testAnEntryOfAnotherShapeIsNotGuessedAt() {
        XCTAssertNil(WindowShortcut.parse(["27": "text"]))
        XCTAssertNil(WindowShortcut.parse(["27": ["enabled": true]]))
        XCTAssertNil(WindowShortcut.parse(entry(parameters: [48, 524288])))
    }

    func testOtherBitsOfTheEventDoNotMatter() {
        let shortcut = WindowShortcut(keyCode: 48, modifiers: CGEventFlags.maskAlternate.rawValue)
        let deviceBits: UInt64 = 0x100 | CGEventFlags.maskSecondaryFn.rawValue | CGEventFlags.maskAlphaShift.rawValue
        XCTAssertTrue(shortcut.matchesExactly(CGEventFlags.maskAlternate.rawValue | deviceBits))
        XCTAssertFalse(shortcut.matchesExactly(CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue))
        XCTAssertFalse(shortcut.matchesExactly(0))
    }
}

final class WindowShortcutTrackerTests: XCTestCase {
    private let option = CGEventFlags.maskAlternate.rawValue
    private let tab: Int64 = 48

    private func tracker() -> WindowShortcutTracker {
        var tracker = WindowShortcutTracker()
        tracker.shortcut = WindowShortcut(keyCode: tab, modifiers: option)
        return tracker
    }

    private func press(_ tracker: inout WindowShortcutTracker, windows: Int? = 1, isRepeat: Bool = false) -> WindowShortcutTracker.Outcome {
        tracker.handle(.keyDown(keyCode: tab, flags: option, isRepeat: isRepeat)) { windows }
    }

    func testTwoWindowsAreLeftToMacOS() {
        var tracker = tracker()
        XCTAssertEqual(press(&tracker, windows: 2), .init())
        XCTAssertFalse(tracker.isHolding)
        XCTAssertEqual(tracker.handle(.keyUp(keyCode: tab)) { nil }, .init(), "macOS gets the whole key press")
    }

    func testNoWindowOrOneIsTaken() {
        for count in [0, 1] {
            var tracker = tracker()
            XCTAssertEqual(press(&tracker, windows: count), .init(swallow: true, command: .begin))
            XCTAssertTrue(tracker.isHolding)
        }
    }

    func testTheWindowsAreCountedOnlyWhenTheShortcutIsPressed() {
        var tracker = tracker()
        var asked = 0
        _ = tracker.handle(.keyDown(keyCode: 0, flags: 0, isRepeat: false)) { asked += 1; return 1 }
        _ = tracker.handle(.keyDown(keyCode: tab, flags: 0, isRepeat: false)) { asked += 1; return 1 }
        XCTAssertEqual(asked, 0, "ordinary typing must not wait for the window server")
    }

    func testAnApplicationThatIsNotForSwitchToHandleIsLeftAlone() {
        var tracker = tracker()
        XCTAssertEqual(press(&tracker, windows: nil), .init())
    }

    func testNoShortcutTakesNothing() {
        var tracker = WindowShortcutTracker()
        XCTAssertEqual(tracker.handle(.keyDown(keyCode: tab, flags: option, isRepeat: false)) { 1 }, .init())
    }

    func testAKeyHeldDownBeforehandDoesNotStartIt() {
        var tracker = tracker()
        XCTAssertEqual(press(&tracker, isRepeat: true), .init())
    }

    func testEachPressMovesAndAHeldKeyKeepsMoving() {
        var tracker = tracker()
        _ = press(&tracker)
        XCTAssertEqual(press(&tracker, windows: nil), .init(swallow: true, command: .advance))
        XCTAssertEqual(press(&tracker, windows: nil, isRepeat: true), .init(swallow: true, command: .advance))
    }

    func testTheArrowsMoveWhileHoldingAndTheirKeyReleasesAreTaken() {
        var tracker = tracker()
        _ = press(&tracker)
        XCTAssertEqual(tracker.handle(.keyDown(keyCode: 125, flags: option, isRepeat: false)) { nil }, .init(swallow: true, command: .advance))
        XCTAssertEqual(tracker.handle(.keyUp(keyCode: 125)) { nil }, .init(swallow: true))
        XCTAssertEqual(tracker.handle(.keyDown(keyCode: 126, flags: option, isRepeat: true)) { nil }, .init(swallow: true, command: .retreat))
        XCTAssertEqual(tracker.handle(.keyUp(keyCode: 126)) { nil }, .init(swallow: true))
    }

    func testTheArrowsBelongToTheApplicationOtherwise() {
        var tracker = tracker()
        XCTAssertEqual(tracker.handle(.keyDown(keyCode: 126, flags: option, isRepeat: false)) { 1 }, .init())
        XCTAssertEqual(tracker.handle(.keyUp(keyCode: 126)) { nil }, .init())
    }

    func testReleasingTheModifierCommits() {
        var tracker = tracker()
        _ = press(&tracker)
        XCTAssertEqual(tracker.handle(.flagsChanged(flags: 0)) { nil }, .init(swallow: false, command: .commit))
        XCTAssertFalse(tracker.isHolding)
        XCTAssertEqual(tracker.handle(.flagsChanged(flags: 0)) { nil }, .init(), "once")
    }

    func testAnotherModifierDoesNotCommit() {
        var tracker = tracker()
        _ = press(&tracker)
        XCTAssertEqual(tracker.handle(.flagsChanged(flags: option | CGEventFlags.maskShift.rawValue)) { nil }, .init())
        XCTAssertTrue(tracker.isHolding)
    }

    func testAnyModifierOfSeveralReleasedCommits() {
        var tracker = WindowShortcutTracker()
        let both = option | CGEventFlags.maskCommand.rawValue
        tracker.shortcut = WindowShortcut(keyCode: tab, modifiers: both)
        _ = tracker.handle(.keyDown(keyCode: tab, flags: both, isRepeat: false)) { 1 }
        XCTAssertEqual(tracker.handle(.flagsChanged(flags: option)) { nil }, .init(swallow: false, command: .commit))
    }

    func testTheKeyReleaseOfATakenKeyIsTakenEvenAfterCommitting() {
        var tracker = tracker()
        _ = press(&tracker)
        _ = tracker.handle(.flagsChanged(flags: 0)) { nil }
        XCTAssertEqual(tracker.handle(.keyUp(keyCode: tab)) { nil }, .init(swallow: true))
        XCTAssertEqual(tracker.handle(.keyUp(keyCode: tab)) { nil }, .init(), "only the one that was taken")
    }

    func testEscapeCancelsAndReleasingAfterwardsDoesNothing() {
        var tracker = tracker()
        _ = press(&tracker)
        XCTAssertEqual(tracker.handle(.keyDown(keyCode: 53, flags: option, isRepeat: false)) { nil }, .init(swallow: true, command: .cancel))
        XCTAssertEqual(tracker.handle(.keyUp(keyCode: 53)) { nil }, .init(swallow: true))
        XCTAssertEqual(tracker.handle(.flagsChanged(flags: 0)) { nil }, .init())
    }

    func testEscapeBelongsToTheApplicationOtherwise() {
        var tracker = tracker()
        XCTAssertEqual(tracker.handle(.keyDown(keyCode: 53, flags: 0, isRepeat: false)) { 1 }, .init())
    }

    func testTheShortcutWithShiftGoesBackWhileHolding() {
        var tracker = tracker()
        _ = press(&tracker)
        let shift = CGEventFlags.maskShift.rawValue
        XCTAssertEqual(tracker.handle(.keyDown(keyCode: tab, flags: option | shift, isRepeat: false)) { nil }, .init(swallow: true, command: .retreat))
        XCTAssertEqual(tracker.handle(.keyDown(keyCode: tab, flags: option | shift, isRepeat: true)) { nil }, .init(swallow: true, command: .retreat))
        XCTAssertEqual(tracker.handle(.flagsChanged(flags: option)) { nil }, .init(), "releasing Shift alone chooses nothing")
        XCTAssertTrue(tracker.isHolding)
    }

    func testStartingWithShiftGoesBack() {
        var tracker = tracker()
        let shift = CGEventFlags.maskShift.rawValue
        XCTAssertEqual(tracker.handle(.keyDown(keyCode: tab, flags: option | shift, isRepeat: false)) { 1 }, .init(swallow: true, command: .beginGoingBack))
        XCTAssertTrue(tracker.isHolding)
    }

    func testTheShortcutWithShiftIsLeftToMacOSWithTwoWindows() {
        var tracker = tracker()
        XCTAssertEqual(tracker.handle(.keyDown(keyCode: tab, flags: option | CGEventFlags.maskShift.rawValue, isRepeat: false)) { 2 }, .init())
        XCTAssertFalse(tracker.isHolding)
    }

    func testAShortcutThatHasShiftHasNoWayBack() {
        var tracker = WindowShortcutTracker()
        let both = option | CGEventFlags.maskShift.rawValue
        tracker.shortcut = WindowShortcut(keyCode: tab, modifiers: both)
        XCTAssertFalse(tracker.shortcut?.matchesGoingBack(both) == true)
        XCTAssertEqual(tracker.handle(.keyDown(keyCode: tab, flags: both, isRepeat: false)) { 1 }, .init(swallow: true, command: .begin))
        XCTAssertEqual(tracker.handle(.keyDown(keyCode: tab, flags: both, isRepeat: false)) { nil }, .init(swallow: true, command: .advance))
    }

    func testALetterJumpsWhileHoldingAndIsNotPassedOn() {
        var tracker = tracker()
        tracker.letterKeys = [40: "k"]
        _ = press(&tracker)
        XCTAssertEqual(tracker.handle(.keyDown(keyCode: 40, flags: option, isRepeat: false)) { nil }, .init(swallow: true, command: .jump("k")))
        XCTAssertEqual(tracker.handle(.keyUp(keyCode: 40)) { nil }, .init(swallow: true))
    }

    func testHoldingALetterDownJumpsOnce() {
        var tracker = tracker()
        tracker.letterKeys = [40: "k"]
        _ = press(&tracker)
        XCTAssertEqual(tracker.handle(.keyDown(keyCode: 40, flags: option, isRepeat: true)) { nil }, .init(swallow: true))
    }

    func testALetterBelongsToTheApplicationOtherwise() {
        var tracker = tracker()
        tracker.letterKeys = [40: "k"]
        XCTAssertEqual(tracker.handle(.keyDown(keyCode: 40, flags: option, isRepeat: false)) { 1 }, .init())
        XCTAssertEqual(tracker.handle(.keyUp(keyCode: 40)) { nil }, .init())
    }

    func testAShortcutOnALetterKeyStillSteps() {
        var tracker = WindowShortcutTracker()
        tracker.shortcut = WindowShortcut(keyCode: 40, modifiers: option)
        tracker.letterKeys = [40: "k"]
        _ = tracker.handle(.keyDown(keyCode: 40, flags: option, isRepeat: false)) { 1 }
        XCTAssertEqual(tracker.handle(.keyDown(keyCode: 40, flags: option, isRepeat: false)) { nil }, .init(swallow: true, command: .advance))
    }

    func testOtherKeysPassWhileHolding() {
        var tracker = tracker()
        _ = press(&tracker)
        XCTAssertEqual(tracker.handle(.keyDown(keyCode: 0, flags: option, isRepeat: false)) { nil }, .init())
    }

    func testTheKeyWithAnExtraModifierDoesNotMoveOrReachAnApplication() {
        var tracker = tracker()
        _ = press(&tracker)
        XCTAssertEqual(tracker.handle(.keyDown(keyCode: tab, flags: option | CGEventFlags.maskControl.rawValue, isRepeat: false)) { nil },
                       .init(swallow: true))
    }

    func testAPanelClosedAnotherWayEndsIt() {
        var tracker = tracker()
        _ = press(&tracker)
        tracker.sessionEnded()
        XCTAssertEqual(tracker.handle(.flagsChanged(flags: 0)) { nil }, .init())
    }
}

final class LetterKeysTests: XCTestCase {
    @MainActor
    func testTheLayoutGivesLowercaseLettersAndDigitsOnly() {
        let letters = LetterKeys.current()
        XCTAssertEqual(letters.count, Set(letters.keys).count)
        XCTAssertFalse(letters.isEmpty)
        for letter in letters.values {
            XCTAssertTrue(letter.isASCII && (letter.isLowercase || letter.isNumber), "\(letter)")
        }
        XCTAssertTrue(Set(letters.values).isSuperset(of: Set("abcdefghijklmnopqrstuvwxyz0123456789")))
        XCTAssertNil(letters[48], "Tab")
        XCTAssertNil(letters[53], "Escape")
        XCTAssertNil(letters[125], "an arrow")
    }
}

final class VisibleWindowCountTests: XCTestCase {
    private func window(pid: pid_t = 1, layer: Int = 0, alpha: Double = 1, width: CGFloat = 800, height: CGFloat = 600) -> FrontWindow.VisibleWindow {
        FrontWindow.VisibleWindow(processIdentifier: pid, layer: layer, alpha: alpha, size: CGSize(width: width, height: height))
    }

    func testCountsOnlyThisApplicationsOrdinaryWindows() {
        let windows = [
            window(), window(width: 230, height: 408),
            window(pid: 2),
            window(layer: 25),
            window(alpha: 0),
            window(width: 1, height: 1)
        ]
        XCTAssertEqual(FrontWindow.visibleWindowCount(of: 1, in: windows), 2)
        XCTAssertEqual(FrontWindow.visibleWindowCount(of: 3, in: windows), 0)
    }
}

final class SwitchInFlightTests: XCTestCase {
    private func row(_ path: String, minimized: Bool = false, front: Bool = false, inThisSpace: Bool = true) -> ListedWindow {
        ListedWindow(title: path, toolTip: nil, isMinimized: minimized, selection: .vscode(path: path), isFrontmost: front, isInThisSpace: inThisSpace)
    }

    private func applied(_ rows: [ListedWindow], chosen: [ListedWindow], identifier: String = "code") -> [ListedWindow] {
        let application = ListedApplication(name: "Code", icon: nil, windows: rows, problem: nil,
                                            application: StubApplication(), bundleIdentifier: "code")
        return SwitchInFlight(applicationIdentifier: identifier, processIdentifier: 1, chosen: chosen)
            .applied(to: [application])[0].windows
    }

    func testTheChosenWindowIsInFrontAndTheOneBeingLeftIsMinimized() {
        let rows = applied([row("a", front: true), row("b", minimized: true), row("c", minimized: true)], chosen: [row("b")])
        XCTAssertEqual(rows.map(\.isFrontmost), [false, true, false])
        XCTAssertEqual(rows.map(\.isMinimized), [true, false, true])
    }

    func testAWindowOnAnotherSpaceIsLeftAsItIs() {
        let rows = applied([row("a"), row("b", minimized: true), row("elsewhere", inThisSpace: false)], chosen: [row("b")])
        XCTAssertFalse(rows[2].isMinimized, "a switch minimizes only this Space's windows")
    }

    func testOtherApplicationsAreLeftAsTheyAre() {
        let rows = applied([row("a", front: true)], chosen: [row("b")], identifier: "another")
        XCTAssertEqual(rows.map(\.isFrontmost), [true])
        XCTAssertEqual(rows.map(\.isMinimized), [false])
    }

    func testPtermSaysForItselfWhichOfItsRowsAreOnShow() {
        let terminal = ListedWindow(title: "t", toolTip: nil, isMinimized: false, selection: .ptermTerminal(id: "1"), isFrontmost: true)
        let rows = applied([terminal], chosen: [row("b")])
        XCTAssertEqual(rows.map(\.isFrontmost), [true])
    }

    func testWithMinimizingOffTheOtherWindowsAreNotMarkedMinimized() {
        let application = ListedApplication(name: "Code", icon: nil,
                                            windows: [row("a", front: true), row("b", minimized: true), row("c", minimized: true)],
                                            problem: nil, application: StubApplication(), bundleIdentifier: "code")
        let inFlight = SwitchInFlight(applicationIdentifier: "code", processIdentifier: 1, chosen: [row("b")], minimizesOtherWindows: false)
        let rows = inFlight.applied(to: [application])[0].windows
        XCTAssertEqual(rows.map(\.isFrontmost), [false, true, false])
        XCTAssertEqual(rows.map(\.isMinimized), [false, false, true])
    }

    func testOnlyASwitchThatMinimizesGivesTheKeysSomethingToGoBy() {
        let minimizing = SwitchInFlight(applicationIdentifier: "code", processIdentifier: 7, chosen: [row("a")]).settling
        XCTAssertEqual(minimizing?.processIdentifier, 7)
        XCTAssertEqual(minimizing?.windowCount, 1)
        XCTAssertNil(SwitchInFlight(applicationIdentifier: "code", processIdentifier: 7, chosen: [row("a")], minimizesOtherWindows: false).settling)
        XCTAssertNil(SwitchInFlight(applicationIdentifier: "code", processIdentifier: nil, chosen: [row("a")]).settling)
    }

    func testHowManyWindowsASwitchLeaves() {
        func count(_ chosen: [ListedWindow]) -> Int {
            SwitchInFlight(applicationIdentifier: "code", processIdentifier: 1, chosen: chosen).windowCountWhenDone
        }
        let terminals = ["1", "2"].map {
            ListedWindow(title: $0, toolTip: nil, isMinimized: false, selection: .ptermTerminal(id: $0))
        }
        XCTAssertEqual(count([row("a")]), 1)
        XCTAssertEqual(count([row("a"), row("b")]), 2, "macOS can switch between them")
        XCTAssertEqual(count(terminals), 1, "pterm shows them in its one window")
    }

    private final class StubApplication: ManagedApplication {
        func windows() -> [ManagedWindow] { [] }
        func focusedWindow() -> ManagedWindow? { nil }
        var isFrontmost: Bool { true }
        func activate() {}
        func terminate() -> Bool { true }
        var isTerminated: Bool { false }
        var questionCount: Int { 0 }
    }
}

final class FrontWindowRefreshTests: XCTestCase {
    private func row(_ title: String, front: Bool = false, selection: SelectedWindow = .vscode(path: "/p")) -> ListedWindow {
        ListedWindow(title: title, toolTip: nil, isMinimized: false, selection: selection, isFrontmost: front)
    }

    func testTheWindowInFrontNowReplacesTheOneInTheOldReading() {
        let rows = [row("a", front: true), row("b")]
        let refreshed = FrontWindow.refreshed(rows, of: 1, in: [.init(processIdentifier: 1, number: 20), .init(processIdentifier: 1, number: 10)]) {
            $0.title == "a" ? 10 : 20
        }
        XCTAssertEqual(refreshed.map(\.isFrontmost), [false, true])
    }

    func testNothingOnScreenMeansNothingInFront() {
        let refreshed = FrontWindow.refreshed([row("a", front: true)], of: 1, in: []) { _ in 10 }
        XCTAssertEqual(refreshed.map(\.isFrontmost), [false])
    }

    func testPtermSaysForItself() {
        let terminal = row("t", front: true, selection: .ptermTerminal(id: "x"))
        XCTAssertEqual(FrontWindow.refreshed([terminal], of: 1, in: []) { _ in nil }.map(\.isFrontmost), [true])
    }
}

@MainActor
final class KeyboardSessionTests: XCTestCase {
    private final class App: ManagedApplication {
        func windows() -> [ManagedWindow] { [] }
        func focusedWindow() -> ManagedWindow? { nil }
        var isFrontmost = true
        func activate() {}
        func terminate() -> Bool { true }
        var isTerminated = false
        var questionCount = 0
    }

    private final class Window: ManagedWindow {
        var isMinimized = false
        var isFullScreen = false
        var exists = true
        func isSame(as other: ManagedWindow) -> Bool { self === other }
        func setMinimized(_ minimized: Bool) throws {}
        func raise() throws {}
        func setFrame(_ frame: CGRect) throws {}
    }

    private func row(_ title: String, front: Bool = false, inThisSpace: Bool = true) -> ListedWindow {
        ListedWindow(title: title, toolTip: nil, isMinimized: false, selection: .direct(Window()),
                     isFrontmost: front, isInThisSpace: inThisSpace)
    }

    private func application(_ name: String, _ windows: [ListedWindow]) -> ListedApplication {
        ListedApplication(name: name, icon: nil, windows: windows, problem: nil, application: App(), bundleIdentifier: "test." + name)
    }

    private var applied: [String] = []

    private func panel() -> (WindowPanelController, PinnedApplications) {
        let suite = "switch.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let pins = PinnedApplications(defaults: defaults)
        return (WindowPanelController(onApply: { [weak self] _, windows in self?.applied = windows.map(\.title) },
                                      onRequestPermission: {}, pins: pins), pins)
    }

    private let anchor = NSRect(x: 100, y: 800, width: 20, height: 20)

    func testTheFirstRowIsAfterTheWindowInFront() {
        XCTAssertEqual(WindowPanelController.nextKeyboardRow(after: nil, in: [row("a"), row("b", front: true), row("c")]), 2)
    }

    func testWithNothingInFrontItStartsAtTheTop() {
        XCTAssertEqual(WindowPanelController.nextKeyboardRow(after: nil, in: [row("a"), row("b")]), 0)
    }

    func testItGoesRound() {
        XCTAssertEqual(WindowPanelController.nextKeyboardRow(after: 1, in: [row("a"), row("b")]), 0)
    }

    func testGoingBackGoesRoundTheOtherWay() {
        let windows = [row("a"), row("b"), row("c")]
        XCTAssertEqual(WindowPanelController.nextKeyboardRow(after: 1, in: windows, step: -1), 0)
        XCTAssertEqual(WindowPanelController.nextKeyboardRow(after: 0, in: windows, step: -1), 2)
    }

    func testGoingBackFromTheWindowInFront() {
        XCTAssertEqual(WindowPanelController.nextKeyboardRow(after: nil, in: [row("a"), row("b", front: true), row("c")], step: -1), 0)
        XCTAssertEqual(WindowPanelController.nextKeyboardRow(after: nil, in: [row("a"), row("b")], step: -1), 1)
    }

    func testGoingBackPassesOverAnotherSpace() {
        let windows = [row("a"), row("b", inThisSpace: false), row("c")]
        XCTAssertEqual(WindowPanelController.nextKeyboardRow(after: 2, in: windows, step: -1), 0)
    }

    func testTheUpArrowMovesBackInThePanel() {
        let (panel, _) = panel()
        panel.beginKeyboardSession(applications: [application("A", [row("a", front: true), row("b"), row("c")])],
                                   frontmostName: "A", below: anchor)
        panel.moveKeyboardSelection(by: 1)
        panel.moveKeyboardSelection(by: -1)
        XCTAssertEqual(panel.keyboardRow, 1)
        panel.commitKeyboardSelection()
        XCTAssertEqual(applied, ["b"])
    }

    func testALetterFindsTheFirstRowStartingWithIt() {
        let windows = [row("alpha"), row("Kilo"), row("kite")]
        XCTAssertEqual(WindowPanelController.keyboardRow(startingWith: "k", after: nil, in: windows), 1, "either case")
        XCTAssertEqual(WindowPanelController.keyboardRow(startingWith: "a", after: nil, in: windows), 0)
        XCTAssertNil(WindowPanelController.keyboardRow(startingWith: "z", after: nil, in: windows))
    }

    func testTheSameLetterGoesToTheNextAndRound() {
        let windows = [row("orange"), row("kilo"), row("owl")]
        XCTAssertEqual(WindowPanelController.keyboardRow(startingWith: "o", after: 0, in: windows), 2)
        XCTAssertEqual(WindowPanelController.keyboardRow(startingWith: "o", after: 2, in: windows), 0)
        XCTAssertEqual(WindowPanelController.keyboardRow(startingWith: "k", after: 1, in: windows), 1, "the only match stays")
    }

    func testALetterPassesOverAnotherSpaceAndOtherScripts() {
        let windows = [row("orange", inThisSpace: false), row("日本語"), row("owl")]
        XCTAssertEqual(WindowPanelController.keyboardRow(startingWith: "o", after: nil, in: windows), 2)
        XCTAssertEqual(WindowPanelController.keyboardRow(startingWith: "1", after: nil, in: [row("1st"), row("2nd")]), 0, "digits too")
    }

    func testPressingLettersInThePanel() {
        let (panel, _) = panel()
        let list = [application("A", [row("alpha", front: true), row("orange"), row("kilo"), row("owl")])]
        panel.beginKeyboardSession(applications: list, frontmostName: "A", below: anchor)
        XCTAssertEqual(panel.keyboardRow, 1, "already on orange, by the press that opened it")
        panel.jumpKeyboardSelection(to: "o")
        XCTAssertEqual(panel.keyboardRow, 1, "the first press of a letter goes to the first match")
        panel.jumpKeyboardSelection(to: "o")
        XCTAssertEqual(panel.keyboardRow, 3)
        panel.jumpKeyboardSelection(to: "o")
        XCTAssertEqual(panel.keyboardRow, 1)
        panel.jumpKeyboardSelection(to: "z")
        XCTAssertEqual(panel.keyboardRow, 1, "no match moves nothing")
        panel.jumpKeyboardSelection(to: "o")
        XCTAssertEqual(panel.keyboardRow, 3, "and does not forget the letter before it")
        panel.moveKeyboardSelection(by: -1)
        panel.jumpKeyboardSelection(to: "o")
        XCTAssertEqual(panel.keyboardRow, 1, "after another key it starts from the top")
        panel.jumpKeyboardSelection(to: "k")
        panel.commitKeyboardSelection()
        XCTAssertEqual(applied, ["kilo"])
    }

    func testAPanelOpenedByTheIconIgnoresLetters() {
        let (panel, _) = panel()
        panel.show(applications: [application("A", [row("a")])], hasPermission: true, frontmostName: "A", below: anchor)
        panel.jumpKeyboardSelection(to: "a")
        XCTAssertNil(panel.keyboardRow)
        panel.close()
    }

    func testASingleWindowStaysChosen() {
        XCTAssertEqual(WindowPanelController.nextKeyboardRow(after: nil, in: [row("a", front: true)]), 0)
    }

    func testAnotherSpaceIsPassedOver() {
        let windows = [row("a", front: true), row("b", inThisSpace: false), row("c")]
        XCTAssertEqual(WindowPanelController.nextKeyboardRow(after: nil, in: windows), 2)
        XCTAssertEqual(WindowPanelController.nextKeyboardRow(after: 2, in: windows), 0)
    }

    func testNothingToReach() {
        XCTAssertNil(WindowPanelController.nextKeyboardRow(after: nil, in: []))
        XCTAssertNil(WindowPanelController.nextKeyboardRow(after: nil, in: [row("a", inThisSpace: false)]))
    }

    func testPressingMovesAndReleasingChoosesThatRow() {
        let (panel, _) = panel()
        panel.beginKeyboardSession(applications: [application("A", [row("a", front: true), row("b"), row("c")])],
                                   frontmostName: "A", below: anchor)
        XCTAssertEqual(panel.keyboardRow, 1)
        panel.moveKeyboardSelection(by: 1)
        XCTAssertEqual(panel.keyboardRow, 2)
        panel.commitKeyboardSelection()
        XCTAssertEqual(applied, ["c"])
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.isKeyboardSession)
    }

    func testStartingBackwardsChoosesTheRowBeforeTheWindowInFront() {
        let (panel, _) = panel()
        panel.beginKeyboardSession(applications: [application("A", [row("a"), row("b", front: true), row("c")])],
                                   frontmostName: "A", below: anchor, step: -1)
        XCTAssertEqual(panel.keyboardRow, 0)
        panel.update(applications: [application("A", [row("a"), row("b"), row("c", front: true)])])
        XCTAssertEqual(panel.keyboardRow, 1, "a new reading works it out the same way")
    }

    func testAQuickPressAndReleaseGoesToTheNextWindow() {
        let (panel, _) = panel()
        panel.beginKeyboardSession(applications: [application("A", [row("a", front: true), row("b")])],
                                   frontmostName: "A", below: anchor)
        panel.commitKeyboardSelection()
        XCTAssertEqual(applied, ["b"])
    }

    func testCancellingChoosesNothing() {
        let (panel, _) = panel()
        var ended = 0
        panel.onKeyboardSessionEnded = { ended += 1 }
        panel.beginKeyboardSession(applications: [application("A", [row("a")])], frontmostName: "A", below: anchor)
        panel.cancelKeyboardSession()
        XCTAssertEqual(applied, [])
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(ended, 0, "the tracker has already ended it")
    }

    func testAnApplicationNotListedIsNotReplacedByTheNextOne() {
        let (panel, _) = panel()
        panel.beginKeyboardSession(applications: [application("Other", [row("o")])], frontmostName: "A", below: anchor)
        XCTAssertNil(panel.selectedApplication)
        XCTAssertNil(panel.keyboardRow)
        panel.commitKeyboardSelection()
        XCTAssertEqual(applied, [])
        XCTAssertFalse(panel.isVisible)
    }

    func testAnApplicationListedByTheNextReadingIsChosen() {
        let (panel, _) = panel()
        panel.beginKeyboardSession(applications: [application("Other", [row("o")])], frontmostName: "A", below: anchor)
        panel.update(applications: [application("A", [row("a"), row("b")]), application("Other", [row("o")])])
        XCTAssertEqual(panel.applications[panel.selectedApplication ?? -1].name, "A")
        XCTAssertEqual(panel.keyboardRow, 0)
    }

    func testANewReadingKeepsTheWindowTheKeysMovedTo() {
        let (panel, _) = panel()
        panel.beginKeyboardSession(applications: [application("A", [row("a", front: true), row("b"), row("c")])],
                                   frontmostName: "A", below: anchor)
        panel.moveKeyboardSelection(by: 1)
        panel.update(applications: [application("A", [row("new"), row("a", front: true), row("b"), row("c")])])
        XCTAssertEqual(panel.keyboardRow, 3)
        panel.commitKeyboardSelection()
        XCTAssertEqual(applied, ["c"])
    }

    func testBeforeMovingANewReadingCanCorrectTheRow() {
        let (panel, _) = panel()
        panel.beginKeyboardSession(applications: [application("A", [row("a", front: true), row("b"), row("c")])],
                                   frontmostName: "A", below: anchor)
        panel.update(applications: [application("A", [row("a"), row("b", front: true), row("c")])])
        XCTAssertEqual(panel.keyboardRow, 2)
    }

    func testAPanelOpenedByTheIconHasNoKeyboardRow() {
        let (panel, _) = panel()
        panel.show(applications: [application("A", [row("a", front: true), row("b")])], hasPermission: true, frontmostName: "A", below: anchor)
        XCTAssertNil(panel.keyboardRow)
        panel.moveKeyboardSelection(by: 1)
        XCTAssertNil(panel.keyboardRow)
        panel.commitKeyboardSelection()
        XCTAssertEqual(applied, [])
        XCTAssertTrue(panel.isVisible)
        panel.close()
    }

    func testClosingAnotherWayTellsTheTracker() {
        let (panel, _) = panel()
        var ended = 0
        panel.onKeyboardSessionEnded = { ended += 1 }
        panel.beginKeyboardSession(applications: [application("A", [row("a")])], frontmostName: "A", below: anchor)
        panel.close()
        XCTAssertEqual(ended, 1)
        panel.close()
        XCTAssertEqual(ended, 1)
    }

    func testAClickDuringTheSessionEndsIt() {
        let (panel, _) = panel()
        var ended = 0
        panel.onKeyboardSessionEnded = { ended += 1 }
        panel.beginKeyboardSession(applications: [application("A", [row("a"), row("b")])], frontmostName: "A", below: anchor)
        panel.clickWindow(row: 1, shift: false)
        XCTAssertEqual(applied, ["b"])
        XCTAssertEqual(ended, 1)
        XCTAssertFalse(panel.isKeyboardSession)
    }
}
