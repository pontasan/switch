import AppKit
import XCTest
@testable import SwitchApp

/// Every test builds a fake VS Code support directory under a fresh temporary
/// directory. The real `~/Library/Application Support/Code` is never read.
final class VSCodeWindowCatalogTests: XCTestCase {
    private struct Fixture {
        let root: URL
        var support: URL { root.appendingPathComponent("Code", isDirectory: true) }
        var catalog: VSCodeWindowCatalog { VSCodeWindowCatalog(supportDirectory: support) }

        func writeState(_ windowsState: Any?) throws {
            var root: [String: Any] = ["theme": "vs-dark"]
            if let windowsState { root["windowsState"] = windowsState }
            try writeRawState(JSONSerialization.data(withJSONObject: root))
        }

        func writeRawState(_ data: Data) throws {
            let url = catalog.stateFileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        @discardableResult
        func writeUntitledWorkspace(id: String, folders: [[String: Any]]) throws -> URL {
            let url = catalog.untitledWorkspacesDirectory
                .appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent("workspace.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["folders": folders, "settings": [:]]).write(to: url)
            return url
        }
    }

    private func withFixture<T>(_ body: (Fixture) throws -> T) throws -> T {
        try withTemporaryDirectory { directory in
            let fixture = Fixture(root: directory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.support.path),
                           "fixture support directory must start empty")
            return try body(fixture)
        }
    }

    /// VS Code stores folder URIs without a trailing slash.
    private static func folderWindow(_ url: URL) -> [String: Any] {
        var uri = url.absoluteString
        if uri.hasSuffix("/") { uri.removeLast() }
        return ["folder": uri, "backupPath": "/unused", "uiState": ["mode": 1]]
    }

    private static func workspaceWindow(_ url: URL) -> [String: Any] {
        ["workspaceIdentifier": ["id": UUID().uuidString, "configURIPath": url.absoluteString],
         "backupPath": "/unused",
         "uiState": ["mode": 1]]
    }

    func testListsFoldersWorkspaceFilesAndUntitledWorkspacesSortedByName() throws {
        try withFixture { fixture in
            let projects = fixture.root.appendingPathComponent("projects", isDirectory: true)
            let folder = projects.appendingPathComponent("orbit_poc", isDirectory: true)
            let japanese = projects.appendingPathComponent("日本語 プロジェクト", isDirectory: true)
            let workspaceFile = projects.appendingPathComponent("alpha-app/alpha-app.code-workspace")
            let absoluteUntitled = try fixture.writeUntitledWorkspace(
                id: "1771522846848",
                folders: [["path": projects.appendingPathComponent("orange-app").path],
                          ["path": "../../../projects/minutes"]])
            let relativeUntitled = try fixture.writeUntitledWorkspace(
                id: "1792650994912",
                folders: [["path": "../../../projects/beta-app"]])
            let namedUntitled = try fixture.writeUntitledWorkspace(
                id: "1793031174709",
                folders: [["name": "Main App", "path": "/tmp/whatever"]])

            try fixture.writeState([
                "openedWindows": [
                    Self.folderWindow(folder),
                    Self.folderWindow(japanese),
                    Self.workspaceWindow(workspaceFile),
                    Self.workspaceWindow(absoluteUntitled),
                    Self.workspaceWindow(relativeUntitled),
                    Self.workspaceWindow(namedUntitled),
                ],
                "lastActiveWindow": Self.folderWindow(folder),
            ])

            let windows = try fixture.catalog.openWindows()
            XCTAssertEqual(windows.map(\.displayName),
                           ["alpha-app", "beta-app", "Main App", "orange-app", "orbit_poc", "日本語 プロジェクト"])
            let byName = Dictionary(uniqueKeysWithValues: windows.map { ($0.displayName, $0) })
            XCTAssertEqual(byName["orbit_poc"]?.kind, .folder)
            XCTAssertEqual(byName["orbit_poc"]?.exactPath, folder.standardizedFileURL.path)
            XCTAssertEqual(byName["日本語 プロジェクト"]?.target.path, japanese.standardizedFileURL.path)
            XCTAssertEqual(byName["alpha-app"], VSCodeWindowEntry(kind: .workspaceFile, displayName: "alpha-app", target: workspaceFile.standardizedFileURL))
            XCTAssertEqual(byName["orange-app"], VSCodeWindowEntry(kind: .untitledWorkspace, displayName: "orange-app", target: absoluteUntitled.standardizedFileURL))
            XCTAssertEqual(byName["beta-app"]?.kind, .untitledWorkspace)
            XCTAssertEqual(byName["beta-app"]?.target, relativeUntitled.standardizedFileURL)
        }
    }

    func testSingleOpenWindowIsReadFromLastActiveWindow() throws {
        // VS Code leaves openedWindows empty when exactly one window is open.
        try withFixture { fixture in
            let folder = fixture.root.appendingPathComponent("kilo-app", isDirectory: true)
            try fixture.writeState(["openedWindows": [], "lastActiveWindow": Self.folderWindow(folder)])
            XCTAssertEqual(try fixture.catalog.openWindows().map(\.displayName), ["kilo-app"])
        }
    }

    func testOpenedWindowsTakePrecedenceOverLastActiveWindow() throws {
        // lastActiveWindow may describe a window that was just closed, so it is
        // not used when openedWindows lists the open windows.
        try withFixture { fixture in
            let open = fixture.root.appendingPathComponent("open", isDirectory: true)
            let other = fixture.root.appendingPathComponent("other", isDirectory: true)
            let closed = fixture.root.appendingPathComponent("closed", isDirectory: true)
            try fixture.writeState(["openedWindows": [Self.folderWindow(open), Self.folderWindow(other), Self.folderWindow(open)],
                                    "lastActiveWindow": Self.folderWindow(closed)])
            XCTAssertEqual(try fixture.catalog.openWindows().map(\.displayName), ["open", "other"])
        }
    }

    func testWindowsThatCannotBeTargetedByLocalPathAreOmitted() throws {
        try withFixture { fixture in
            let local = fixture.root.appendingPathComponent("local", isDirectory: true)
            try fixture.writeState(["openedWindows": [
                Self.folderWindow(local),
                ["backupPath": "/unused", "uiState": ["mode": 1]],                                     // empty window
                ["folder": "vscode-remote://ssh-remote%2Bhost/home/me/app", "remoteAuthority": "ssh-remote+host"],
                ["folder": "vscode-vfs://github/owner/repo"],                                           // virtual workspace
            ]])
            XCTAssertEqual(try fixture.catalog.openWindows().map(\.displayName), ["local"])
        }
    }

    func testDuplicateNamesShowTheirParentDirectory() {
        let entries = [
            VSCodeWindowEntry(kind: .folder, displayName: "app", target: URL(fileURLWithPath: "/alpha/app")),
            VSCodeWindowEntry(kind: .folder, displayName: "app", target: URL(fileURLWithPath: "/beta/app")),
            VSCodeWindowEntry(kind: .folder, displayName: "solo", target: URL(fileURLWithPath: "/p/solo"))
        ]
        XCTAssertEqual(VSCodeWindowCatalog.displayTitles(for: entries), ["app — alpha", "app — beta", "solo"])
    }

    func testSavedBoundsAreReadFromTheWindowState() throws {
        try withFixture { fixture in
            let folder = fixture.root.appendingPathComponent("projects/a", isDirectory: true)
            var window = Self.folderWindow(folder)
            window["uiState"] = ["mode": 1, "x": 90, "y": 33, "width": 1200, "height": 800]
            try fixture.writeState(["openedWindows": [window]])
            XCTAssertEqual(try fixture.catalog.openWindows().first?.bounds, CGRect(x: 90, y: 33, width: 1200, height: 800))
        }
    }

    func testExactPathKeepsTheUnicodeFormOfTheStoredURI() throws {
        let composed = try VSCodeWindowCatalog.exactPath(ofFileURI: "file:///a/%E3%83%90/w.code-workspace", key: "k")
        XCTAssertEqual(Array(composed.utf8), Array("/a/\u{30D0}/w.code-workspace".utf8))
        let decomposed = try VSCodeWindowCatalog.exactPath(ofFileURI: "file:///a/%E3%83%8F%E3%82%99/w.code-workspace", key: "k")
        XCTAssertEqual(Array(decomposed.utf8), Array("/a/\u{30CF}\u{3099}/w.code-workspace".utf8))
    }

    func testMissingStateFileMeansVSCodeHasNoStoredWindows() throws {
        try withFixture { fixture in
            XCTAssertEqual(try fixture.catalog.openWindows(), [])
        }
    }

    func testStateWithoutWindowsStateHasNoWindows() throws {
        try withFixture { fixture in
            try fixture.writeState(nil)
            XCTAssertEqual(try fixture.catalog.openWindows(), [])
        }
    }

    func testEmptyUntitledWorkspaceUsesVSCodeUntitledName() throws {
        try withFixture { fixture in
            let workspace = try fixture.writeUntitledWorkspace(id: "1", folders: [])
            try fixture.writeState(["openedWindows": [Self.workspaceWindow(workspace)]])
            XCTAssertEqual(try fixture.catalog.openWindows().map(\.displayName), [VSCodeWindowCatalog.untitledWorkspaceDisplayName])
        }
    }

    func testDotDotSegmentsCannotDisguiseAFileAsAnUntitledWorkspace() throws {
        try withFixture { fixture in
            // Resolves outside <support>/Workspaces, so it is a workspace file and
            // Switch must not try to read it as an untitled workspace.
            let disguised = URL(string: fixture.catalog.untitledWorkspacesDirectory.absoluteString + "../outside.code-workspace")!
            try fixture.writeState(["openedWindows": [Self.workspaceWindow(disguised)]])
            let windows = try fixture.catalog.openWindows()
            XCTAssertEqual(windows.map(\.kind), [.workspaceFile])
            XCTAssertEqual(windows.map(\.displayName), ["outside"])
            XCTAssertEqual(windows.first?.target.path, fixture.support.appendingPathComponent("outside.code-workspace").path)
        }
    }

    func testMalformedStateIsReportedInsteadOfGuessed() throws {
        try withFixture { fixture in
            let cases: [(Data, VSCodeWindowCatalogError)] = [
                (Data("[]".utf8), .malformedState("root is not an object")),
                (try JSONSerialization.data(withJSONObject: ["windowsState": "x"]), .malformedState("windowsState is not an object")),
                (try JSONSerialization.data(withJSONObject: ["windowsState": ["openedWindows": "x"]]), .malformedState("openedWindows is not an array of objects")),
                (try JSONSerialization.data(withJSONObject: ["windowsState": ["openedWindows": [["folder": 3]]]]), .malformedState("folder is not a string")),
                (try JSONSerialization.data(withJSONObject: ["windowsState": ["openedWindows": [["folder": "file:///a", "workspaceIdentifier": ["configURIPath": "file:///b"]]]]]),
                 .malformedState("window has both folder and workspaceIdentifier")),
                (try JSONSerialization.data(withJSONObject: ["windowsState": ["openedWindows": [["folder": "relative/path"]]]]), .malformedState("folder is not a valid URI")),
            ]
            for (data, expected) in cases {
                try fixture.writeRawState(data)
                XCTAssertThrowsError(try fixture.catalog.openWindows()) { error in
                    XCTAssertEqual(error as? VSCodeWindowCatalogError, expected)
                }
            }
            try fixture.writeRawState(Data("{".utf8))
            XCTAssertThrowsError(try fixture.catalog.openWindows())
        }
    }

    func testMissingUntitledWorkspaceFileIsReported() throws {
        try withFixture { fixture in
            let missing = fixture.catalog.untitledWorkspacesDirectory.appendingPathComponent("404/workspace.json")
            try fixture.writeState(["openedWindows": [Self.workspaceWindow(missing)]])
            XCTAssertThrowsError(try fixture.catalog.openWindows()) { error in
                guard case .malformedWorkspace(let path, _)? = error as? VSCodeWindowCatalogError else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertEqual(path, missing.standardizedFileURL.path)
            }
        }
    }
}

/// Runs the real opener against a fake VS Code bundle in a temporary directory.
/// The fake `code` command records what it receives. The real VS Code is never launched.
@MainActor
final class VSCodeCLIWindowOpenerTests: XCTestCase {
    private func withFakeApplication(script: String, _ body: (_ app: URL, _ root: URL) throws -> Void) throws {
        try withTemporaryDirectory { root in
            let app = root.appendingPathComponent("Fake Code.app", isDirectory: true)
            let command = app.appendingPathComponent("Contents/Resources/app/bin/code")
            try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ("#!/bin/sh\n" + script).write(to: command, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
            try body(app, root)
        }
    }

    private func open(_ target: URL, app: URL) -> Error? { open(path: target.path, app: app) }

    private func open(path: String, app: URL) -> Error? {
        let finished = expectation(description: "open finished")
        var result: Error?
        VSCodeCLIWindowOpener().open(path: path, withApplicationAt: app) { error in
            result = error
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        return result
    }

    func testInvocationPassesOnlyThePathAndAnExplicitEnvironment() {
        let invocation = VSCodeCLIWindowOpener.invocation(
            path: "/home/Code/Workspaces/1/workspace.json",
            applicationURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true),
            homeDirectory: "/home")
        XCTAssertEqual(invocation.executable.path, "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code")
        XCTAssertEqual(invocation.arguments, ["/home/Code/Workspaces/1/workspace.json"])
        XCTAssertEqual(invocation.environment, ["HOME": "/home", "PATH": "/usr/bin:/bin"])
    }

    func testExtraArgumentsComeBeforeThePath() throws {
        try withFakeApplication(script: "printf '%s\\n' \"$@\" > \"$(dirname \"$0\")/received\"\n") { app, root in
            let finished = expectation(description: "open finished")
            VSCodeCLIWindowOpener(extraArguments: ["--user-data-dir", "/d"]).open(path: root.path, withApplicationAt: app) { _ in finished.fulfill() }
            wait(for: [finished], timeout: 10)
            let received = try String(contentsOf: app.appendingPathComponent("Contents/Resources/app/bin/received"), encoding: .utf8)
            XCTAssertEqual(received.split(separator: "\n").map(String.init), ["--user-data-dir", "/d", root.path])
        }
    }

    func testUntitledWorkspaceIsPassedToTheCodeCommandWithoutInheritedEnvironment() throws {
        // Regression: through NSWorkspace.open, VS Code opened workspace.json as a
        // text tab in another window and the requested window stayed behind.
        try withFakeApplication(script: "printf '%s\\n' \"$#\" \"$1\" \"${NODE_OPTIONS-unset}\" \"${VSCODE_IPC_HOOK_CLI-unset}\" > \"$(dirname \"$1\")/received\"\n") { app, root in
            let directory = root.appendingPathComponent("Code/Workspaces/1 日本語", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let workspace = directory.appendingPathComponent("workspace.json")
            try Data("{}".utf8).write(to: workspace)
            setenv("NODE_OPTIONS", "--require=/tmp/injected.js", 1)
            setenv("VSCODE_IPC_HOOK_CLI", "/tmp/injected.sock", 1)
            defer {
                unsetenv("NODE_OPTIONS")
                unsetenv("VSCODE_IPC_HOOK_CLI")
            }

            XCTAssertNil(open(workspace, app: app))
            let received = try String(contentsOf: directory.appendingPathComponent("received"), encoding: .utf8)
            XCTAssertEqual(received.split(separator: "\n").map(String.init), ["1", workspace.path, "unset", "unset"])
        }
    }

    func testPathBytesReachTheCommandInTheFormVSCodeStoredThem() throws {
        // Regression: Foundation.Process decomposed the path, so VS Code saw another
        // workspace and opened a new window. Swift's == treats NFC and NFD as equal,
        // so this compares bytes.
        let composed = "/\u{30B5}\u{30FC}\u{30D0}"
        let decomposed = "/\u{30B5}\u{30FC}\u{30CF}\u{3099}"
        for spelling in [composed, decomposed] {
            try withFakeApplication(script: "printf '%s' \"$1\" > \"$(dirname \"$0\")/received\"\n") { app, root in
                try FileManager.default.createDirectory(atPath: root.path + composed, withIntermediateDirectories: true)
                let path = root.path + spelling
                XCTAssertNil(open(path: path, app: app))
                let received = try Data(contentsOf: app.appendingPathComponent("Contents/Resources/app/bin/received"))
                XCTAssertEqual(Array(received), Array(path.utf8))
            }
        }
    }

    func testMissingTargetIsReportedWithoutRunningTheCommand() throws {
        // The real command would create a new file at a missing path.
        try withFakeApplication(script: "touch \"$(dirname \"$0\")/ran\"\n") { app, root in
            let missing = root.appendingPathComponent("gone/workspace.json")
            XCTAssertEqual(open(missing, app: app) as? VSCodeWindowOpenError, .targetMissing(path: missing.path))
            let marker = app.appendingPathComponent("Contents/Resources/app/bin/ran")
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testCommandFailureReportsStatusAndMessage() throws {
        try withFakeApplication(script: "echo 'cannot connect' >&2\nexit 3\n") { app, root in
            XCTAssertEqual(open(root, app: app) as? VSCodeWindowOpenError,
                           .commandFailed(status: 3, message: "cannot connect"))
        }
    }

    func testMissingCommandIsReported() throws {
        try withTemporaryDirectory { root in
            XCTAssertNotNil(open(root, app: root.appendingPathComponent("NoSuch.app", isDirectory: true)))
        }
    }
}

final class VSCodeWindowOrderTests: XCTestCase {
    private typealias Server = VSCodeWindowOrder.ServerWindow
    private typealias Saved = VSCodeWindowOrder.SavedWindow

    private func frame(_ x: Int, height: Int = 800) -> CGRect {
        CGRect(x: x, y: 33, width: 800, height: height)
    }

    private func server(_ numbers: [Int], on shared: CGRect? = nil) -> [Server] {
        numbers.map { Server(number: $0, frame: shared ?? frame($0), layer: 0) }
    }

    private func saved(_ paths: [String?], on shared: CGRect? = nil) -> [Saved] {
        paths.map { Saved(path: $0, bounds: shared) }
    }

    /// The windows are named after their numbers: 7 is "w7".
    private func assigned(_ saved: [Saved], _ server: [Server], listed: [Int], savedInThisRun: Bool = true) -> [String: String]? {
        VSCodeWindowOrder.assignments(saved: saved, server: server, windows: listed.map { (window: "w\($0)", number: $0) }, savedInThisRun: savedInThisRun)
            .map { pairs in Dictionary(uniqueKeysWithValues: pairs.compactMap { pair in pair.path.map { ($0, pair.window) } }) }
    }

    func testPathsPairWithWindowsByNumberNotByListOrder() {
        XCTAssertEqual(assigned(saved(["a", "b"]), server([9, 3]), listed: [9, 3]), ["a": "w3", "b": "w9"])
    }

    func testWindowsOnOnePlacePairLikeAnyOthers() {
        let same = frame(5)
        XCTAssertEqual(assigned(saved(["a", "b", "c"], on: same), server([1, 2, 3], on: same), listed: [3, 1, 2]),
                       ["a": "w1", "b": "w2", "c": "w3"])
    }

    func testHelperWindowsDoNotCount() {
        let helpers = [Server(number: 1, frame: CGRect(x: 0, y: 0, width: 300, height: 30), layer: 0),
                       Server(number: 2, frame: frame(2), layer: 25)]
        XCTAssertEqual(assigned(saved(["a"]), helpers + server([5]), listed: [5]), ["a": "w5"])
    }

    func testAHiddenWindowDoesNotCountWhenEveryWindowIsListed() {
        XCTAssertEqual(assigned(saved(["a", "b"]), server([1, 2, 3]), listed: [1, 3]), ["a": "w1", "b": "w3"])
    }

    func testAWindowOnAnotherSpaceHoldsItsPlace() {
        XCTAssertEqual(assigned(saved(["a", "other space", "c"]), server([1, 2, 3]), listed: [1, 3]), ["a": "w1", "c": "w3"])
    }

    func testAWindowWithNoPathHoldsItsPlaceAndIsAssignedNoPath() throws {
        let pairs = try XCTUnwrap(VSCodeWindowOrder.assignments(saved: saved(["a", nil, "c"]), server: server([1, 2, 3]),
                                                                windows: [("w1", 1), ("w2", 2), ("w3", 3)], savedInThisRun: true))
        XCTAssertEqual(pairs.filter { $0.path == nil }.map(\.window), ["w2"])
        XCTAssertEqual(pairs.filter { $0.path != nil }.map(\.window).sorted(), ["w1", "w3"])
    }

    // MARK: A file from before this run of VS Code

    func testAnOldFilePairsWhenEveryWindowIsWhereItSays() {
        let list = [Saved(path: "a", bounds: frame(1)), Saved(path: "b", bounds: frame(2))]
        XCTAssertEqual(assigned(list, server([1, 2]), listed: [1, 2], savedInThisRun: false), ["a": "w1", "b": "w2"])
    }

    func testAnOldFilePairsNothingWhenAWindowIsElsewhere() {
        let list = [Saved(path: "a", bounds: frame(2)), Saved(path: "b", bounds: frame(1))]
        XCTAssertNil(assigned(list, server([1, 2]), listed: [1, 2], savedInThisRun: false))
    }

    func testAFileFromThisRunPairsEvenIfAWindowHasMovedSince() {
        let list = [Saved(path: "a", bounds: frame(2)), Saved(path: "b", bounds: frame(1))]
        XCTAssertEqual(assigned(list, server([1, 2]), listed: [1, 2]), ["a": "w1", "b": "w2"])
    }

    // MARK: Windows VS Code did not save

    func testADetachedEditorInTheMiddleIsFoundByTheSavedBounds() {
        let list = [Saved(path: "a", bounds: frame(1)), Saved(path: "c", bounds: frame(3))]
        XCTAssertEqual(assigned(list, server([1, 2, 3]), listed: [1, 2, 3]), ["a": "w1", "c": "w3"])
    }

    func testWindowsOnOnePlaceAroundADetachedEditorPairWhenTheOrderLeavesOneWay() {
        let same = frame(5)
        let list = saved(["a", "b"], on: same)
        let servers = [Server(number: 1, frame: same, layer: 0), Server(number: 2, frame: frame(2), layer: 0), Server(number: 3, frame: same, layer: 0)]
        XCTAssertEqual(assigned(list, servers, listed: [1, 2, 3]), ["a": "w1", "b": "w3"])
    }

    func testAPlaceThatCouldBeEitherOfTwoWindowsPairsNothing() {
        let same = frame(5)
        let servers = server([1, 2, 3], on: same)
        XCTAssertEqual(assigned(saved(["a"], on: same), servers, listed: [1, 2, 3]), [:], "any of the three could be it")
        XCTAssertEqual(assigned(saved(["a", "b"], on: same), servers, listed: [1, 2, 3]), [:], "either of two could hold each")
    }

    func testOutOfDateBoundsPairNothing() {
        XCTAssertNil(assigned([Saved(path: "a", bounds: frame(99))], server([1, 2]), listed: [1, 2]))
    }

    func testBoundsOutOfOrderPairNothing() {
        let list = [Saved(path: "a", bounds: frame(2)), Saved(path: "b", bounds: frame(1))]
        XCTAssertNil(assigned(list, server([1, 2, 3]), listed: [1, 2, 3]))
    }

    func testAClosedWindowStillSavedPairsNothing() {
        XCTAssertNil(assigned([Saved(path: "a", bounds: frame(1)), Saved(path: "b", bounds: frame(9))], server([1]), listed: [1]))
    }

    func testNoSavedWindowsPairNothing() {
        XCTAssertNil(assigned([], server([1]), listed: [1]))
    }

    // MARK: Windows without a path

    private func withoutPath(unpaired: Int, unknown: [String], fromOrder: [String] = []) -> [String] {
        VSCodeWindowsWithoutPath.select(unpairedPaths: unpaired, unknown: unknown, fromOrder: fromOrder, isSame: ==)
    }

    func testWithEveryPathPairedTheOtherWindowsHaveNoPath() {
        XCTAssertEqual(withoutPath(unpaired: 0, unknown: ["empty", "detached"]), ["empty", "detached"])
    }

    func testAWindowThatMayBelongToAPathIsNotListedTwice() {
        XCTAssertEqual(withoutPath(unpaired: 1, unknown: ["maybe a"]), [], "it may be the window of the unpaired path")
    }

    func testTheOrderSaysWhichWindowHasNoPathWhileAPathIsOnAnotherSpace() {
        XCTAssertEqual(withoutPath(unpaired: 1, unknown: ["empty", "maybe a"], fromOrder: ["empty"]), ["empty"])
    }

    // MARK: Titles and the saved list

    func testTitlesCheckOnlyNamedWindows() {
        XCTAssertTrue(VSCodeWindowOrder.titlesAgree([("kilo-app", "task.md — kilo-app"), (nil, "Untitled (Workspace)")]))
        XCTAssertFalse(VSCodeWindowOrder.titlesAgree([("kilo-app", "task.md — golf-task")]))
        XCTAssertFalse(VSCodeWindowOrder.titlesAgree([("kilo-app", nil)]))
    }

    func testTitlesCompareAcrossUnicodeForms() {
        let composed = "\u{30B5}\u{30FC}\u{30D0}"
        let decomposed = "\u{30B5}\u{30FC}\u{30CF}\u{3099}"
        XCTAssertTrue(VSCodeWindowOrder.titlesAgree([(composed, "a — \(decomposed)")]))
        XCTAssertTrue(VSCodeWindowOrder.titlesAgree([(decomposed, "a — \(composed)")]))
    }

    func testTheSavedOrderIsKeptAndHoldsAPlaceForUntargetableWindows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = VSCodeWindowCatalog(supportDirectory: directory)
        try FileManager.default.createDirectory(at: catalog.stateFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let state = #"{"windowsState":{"openedWindows":[{"folder":"file:///z/zeta","uiState":{"x":1,"y":2,"width":3,"height":4}},{"folder":"file:///r","remoteAuthority":"ssh"},{"folder":"file:///a/alpha"}]}}"#
        try state.write(to: catalog.stateFileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(try catalog.pathsInCreationOrder(), ["/z/zeta", nil, "/a/alpha"])
        XCTAssertEqual(try catalog.windowsInCreationOrder().first?.bounds, CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(try catalog.openWindows().map(\.exactPath), ["/a/alpha", "/z/zeta"])
    }
}
