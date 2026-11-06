import AppKit
import Carbon.HIToolbox
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

    func testShiftAddedGoesBack() {
        let option = CGEventFlags.maskAlternate.rawValue
        let shift = CGEventFlags.maskShift.rawValue
        XCTAssertEqual(WindowShortcut(keyCode: 48, modifiers: option).goingBack, WindowShortcut(keyCode: 48, modifiers: option | shift))
        XCTAssertNil(WindowShortcut(keyCode: 48, modifiers: option | shift).goingBack, "a shortcut that has Shift has no way back")
    }

    func testTheModifiersAsCarbonNamesThem() {
        XCTAssertEqual(WindowShortcut.carbonModifiers(CGEventFlags.maskAlternate.rawValue), UInt32(optionKey))
        XCTAssertEqual(WindowShortcut.carbonModifiers(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue),
                       UInt32(cmdKey | shiftKey))
        XCTAssertEqual(WindowShortcut.carbonModifiers(CGEventFlags.maskControl.rawValue | 0x100 | CGEventFlags.maskSecondaryFn.rawValue),
                       UInt32(controlKey), "other bits are not modifiers")
    }

    func testHeldGoesByTheShortcutsModifiersOnly() {
        let shortcut = WindowShortcut(keyCode: 48, modifiers: CGEventFlags.maskAlternate.rawValue)
        XCTAssertTrue(shortcut.isHeld(CGEventFlags.maskAlternate.rawValue | 0x100 | CGEventFlags.maskShift.rawValue))
        XCTAssertFalse(shortcut.isHeld(0x100))
    }
}

final class WindowShortcutTrackerTests: XCTestCase {
    private let option = CGEventFlags.maskAlternate.rawValue

    private func tracker() -> WindowShortcutTracker {
        var tracker = WindowShortcutTracker()
        tracker.shortcut = WindowShortcut(keyCode: 48, modifiers: option)
        return tracker
    }

    private func started() -> WindowShortcutTracker {
        var tracker = tracker()
        _ = tracker.handle(.pressed(.shortcut))
        return tracker
    }

    func testTheShortcutAlwaysBegins() {
        var tracker = tracker()
        XCTAssertEqual(tracker.handle(.pressed(.shortcut)), .begin, "whatever the number of windows")
        XCTAssertTrue(tracker.isHolding)
    }

    func testStartingWithShiftGoesBack() {
        var tracker = tracker()
        XCTAssertEqual(tracker.handle(.pressed(.shortcutGoingBack)), .beginGoingBack)
        XCTAssertTrue(tracker.isHolding)
    }

    func testNoShortcutBeginsNothing() {
        var tracker = WindowShortcutTracker()
        XCTAssertNil(tracker.handle(.pressed(.shortcut)))
    }

    func testEachPressMovesAndAHeldKeyKeepsMoving() {
        var tracker = started()
        XCTAssertEqual(tracker.handle(.pressed(.shortcut)), .advance)
        XCTAssertEqual(tracker.handle(.pressed(.shortcut)), .advance, "a hot key held down says so again")
        XCTAssertEqual(tracker.handle(.pressed(.shortcutGoingBack)), .retreat)
    }

    func testReleasingTheModifierCommitsOnce() {
        var tracker = started()
        XCTAssertNil(tracker.handle(.modifiersChanged(flags: option | 0x100)), "still held")
        XCTAssertEqual(tracker.handle(.modifiersChanged(flags: 0x100)), .commit)
        XCTAssertFalse(tracker.isHolding)
        XCTAssertNil(tracker.handle(.modifiersChanged(flags: 0)), "once")
    }

    func testAnotherModifierDoesNotCommit() {
        var tracker = started()
        XCTAssertNil(tracker.handle(.modifiersChanged(flags: option | CGEventFlags.maskShift.rawValue)))
        XCTAssertNil(tracker.handle(.modifiersChanged(flags: option)), "letting Shift go alone chooses nothing")
        XCTAssertTrue(tracker.isHolding)
    }

    func testAnyModifierOfSeveralReleasedCommits() {
        var tracker = WindowShortcutTracker()
        tracker.shortcut = WindowShortcut(keyCode: 48, modifiers: option | CGEventFlags.maskCommand.rawValue)
        _ = tracker.handle(.pressed(.shortcut))
        XCTAssertEqual(tracker.handle(.modifiersChanged(flags: option)), .commit)
    }

    func testAPanelClosedAnotherWayEndsIt() {
        var tracker = started()
        tracker.sessionEnded()
        XCTAssertNil(tracker.handle(.modifiersChanged(flags: 0)))
        XCTAssertEqual(tracker.handle(.pressed(.shortcut)), .begin)
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

    func testTheShortcutGoesRoundThePinnedWindows() {
        let (panel, pins) = panel()
        let windows = [row("a", front: true), row("b"), row("c"), row("d"), row("e")]
        for title in ["b", "d"] { pins.toggleWindow(title, of: "test.A") }
        panel.beginKeyboardSession(applications: [application("A", windows)], frontmostName: "A", below: anchor)
        let titles = { panel.keyboardRow.map { panel.applications[0].windows[$0].title } }
        XCTAssertEqual(titles(), "b")
        XCTAssertEqual(panel.pinnedRing?.count, 2)
        panel.moveKeyboardSelection(by: 1)
        XCTAssertEqual(titles(), "d")
        panel.moveKeyboardSelection(by: 1)
        XCTAssertEqual(titles(), "b", "round again")
        panel.moveKeyboardSelection(by: -1)
        XCTAssertEqual(titles(), "d", "and the other way")
        panel.moveKeyboardSelection(by: 1, followingPins: false)
        XCTAssertNotEqual(titles(), "b", "the arrows go to every row")
        panel.moveKeyboardSelection(by: 1)
        XCTAssertEqual(titles(), "b", "from there the shortcut goes on to the next pinned window")
        panel.cancelKeyboardSession()
    }

    func testOnePinnedWindowLeavesEveryRowToTheShortcut() {
        let (panel, pins) = panel()
        pins.toggleWindow("c", of: "test.A")
        panel.beginKeyboardSession(applications: [application("A", [row("a", front: true), row("b"), row("c")])],
                                   frontmostName: "A", below: anchor)
        XCTAssertNil(panel.pinnedRing)
        let titles = { panel.keyboardRow.map { panel.applications[0].windows[$0].title } }
        // c, pinned, is at the top: c, a, b. The keys start after a, the window in front.
        XCTAssertEqual(titles(), "b")
        panel.moveKeyboardSelection(by: 1)
        XCTAssertEqual(titles(), "c")
        panel.moveKeyboardSelection(by: 1)
        XCTAssertEqual(titles(), "a", "every row, pinned or not")
        panel.cancelKeyboardSession()
    }

    func testAPinnedWindowOnAnotherSpaceIsNotInTheRing() {
        let (panel, pins) = panel()
        for title in ["b", "c"] { pins.toggleWindow(title, of: "test.A") }
        panel.reload(applications: [application("A", [row("a", front: true), row("b"), row("c", inThisSpace: false)])],
                     hasPermission: true, frontmostName: "A")
        XCTAssertNil(panel.pinnedRing, "one reachable pinned window is not a ring")
        panel.close()
    }

    func testEveryWindowOnShowStandsOut() {
        let accent = WindowPanelController.windowTextColor(row("front", front: true))
        let side = ListedWindow(title: "side", toolTip: nil, isMinimized: false, selection: .direct(Window()))
        let minimized = ListedWindow(title: "m", toolTip: nil, isMinimized: true, selection: .direct(Window()))
        XCTAssertEqual(WindowPanelController.windowTextColor(side), accent, "a window side by side with the one in front")
        XCTAssertNotEqual(WindowPanelController.windowTextColor(minimized), accent)
        XCTAssertNotEqual(WindowPanelController.windowTextColor(row("elsewhere", inThisSpace: false)), accent)
    }

    private func key(_ keyCode: UInt16, isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: 0,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: isRepeat, keyCode: keyCode)!
    }

    func testThePanelTakesTheArrowsAndLettersWhileTheShortcutIsHeld() {
        let (panel, _) = panel()
        panel.letterKeys = [40: "k", 31: "o"]
        let list = [application("A", [row("alpha", front: true), row("orange"), row("kilo"), row("owl")])]
        XCTAssertFalse(panel.takeKeyboardSessionKey(key(40)), "not while the panel is not open from the keys")
        panel.beginKeyboardSession(applications: list, frontmostName: "A", below: anchor)
        XCTAssertEqual(panel.keyboardRow, 1)
        XCTAssertTrue(panel.takeKeyboardSessionKey(key(125)))
        XCTAssertEqual(panel.keyboardRow, 2)
        XCTAssertTrue(panel.takeKeyboardSessionKey(key(126)))
        XCTAssertEqual(panel.keyboardRow, 1)
        XCTAssertTrue(panel.takeKeyboardSessionKey(key(40)))
        XCTAssertEqual(panel.keyboardRow, 2, "k goes to kilo")
        XCTAssertTrue(panel.takeKeyboardSessionKey(key(31)))
        XCTAssertTrue(panel.takeKeyboardSessionKey(key(31, isRepeat: true)), "a held letter is still taken")
        XCTAssertEqual(panel.keyboardRow, 1, "o once, to orange: holding it down is not asking again")
        XCTAssertFalse(panel.takeKeyboardSessionKey(key(48)), "other keys go on as before")
        panel.cancelKeyboardSession()
    }

    func testTheArrowsReachEveryRowEvenWithWindowsPinned() {
        let (panel, pins) = panel()
        for title in ["b", "d"] { pins.toggleWindow(title, of: "test.A") }
        panel.beginKeyboardSession(applications: [application("A", [row("a", front: true), row("b"), row("c"), row("d")])],
                                   frontmostName: "A", below: anchor)
        let start = panel.keyboardRow
        XCTAssertTrue(panel.takeKeyboardSessionKey(key(125)))
        XCTAssertEqual(panel.keyboardRow, start.map { ($0 + 1) % 4 })
        panel.cancelKeyboardSession()
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
