import CoreGraphics
import Foundation

/// A Visual Studio Code window that Switch can bring to the front.
struct VSCodeWindowEntry: Equatable {
    enum Kind: Equatable {
        /// A window that has a single folder open.
        case folder
        /// A window that has a saved `*.code-workspace` file open.
        case workspaceFile
        /// A window that has an untitled multi-root workspace open. VS Code keeps
        /// its configuration in `<support>/Workspaces/<id>/workspace.json`.
        case untitledWorkspace
    }

    let kind: Kind
    let displayName: String
    /// Local file URL of the folder or workspace configuration file. When this
    /// URL is passed to VS Code, VS Code focuses the window that already has it
    /// open. It does not open a second window.
    let target: URL
    /// The path exactly as VS Code stored it, for handing back to VS Code. VS Code
    /// identifies a workspace by a hash of its path bytes, so NFC and NFD spellings
    /// of one path are different workspaces to it, and the wrong one opens a new
    /// window. `URL.standardizedFileURL` and `URL.path` can change the spelling.
    let exactPath: String
    /// Where VS Code last saved the window to be, in screen coordinates with the
    /// origin at the top left.
    let bounds: CGRect?

    init(kind: Kind, displayName: String, target: URL, exactPath: String? = nil, bounds: CGRect? = nil) {
        self.kind = kind
        self.displayName = displayName
        self.target = target
        self.exactPath = exactPath ?? target.path
        self.bounds = bounds
    }
}

enum VSCodeWindowCatalogError: Error, Equatable, CustomStringConvertible {
    case malformedState(String)
    case malformedWorkspace(path: String, reason: String)

    var description: String {
        switch self {
        case .malformedState(let reason):
            return "VS Code window state is malformed: \(reason)"
        case .malformedWorkspace(let path, let reason):
            return "VS Code workspace \(path) is malformed: \(reason)"
        }
    }
}

/// Lists the open Visual Studio Code windows from VS Code's own persisted
/// window state. No Accessibility or Screen Recording permission is needed.
///
/// Source: the `windowsState` key in `<support>/User/globalStorage/storage.json`.
/// VS Code rewrites this key when one of its windows loses focus, when a window
/// closes, and on shutdown. If more than one window is open, every window is
/// listed in `openedWindows`. If only one window is open, `openedWindows` is
/// empty and that window appears only in `lastActiveWindow`.
///
/// Window titles are deliberately never used. Untitled workspaces all share the
/// same title, so a title cannot identify a project.
struct VSCodeWindowCatalog {
    static let applicationBundleIdentifier = "com.microsoft.VSCode"
    static let untitledWorkspaceDisplayName = "Untitled (Workspace)"

    /// VS Code's per-user support directory (`~/Library/Application Support/Code`).
    let supportDirectory: URL

    var stateFileURL: URL {
        supportDirectory
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("storage.json", isDirectory: false)
    }

    var untitledWorkspacesDirectory: URL {
        supportDirectory.appendingPathComponent("Workspaces", isDirectory: true)
    }

    static func userSupportDirectory(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(for: .applicationSupportDirectory,
                            in: .userDomainMask,
                            appropriateFor: nil,
                            create: false)
            .appendingPathComponent("Code", isDirectory: true)
    }

    /// Returns the open windows sorted by display name.
    /// An empty list means VS Code has never stored any window state.
    /// Display names are usually unique. When two windows share a name (for
    /// example two folders named `app` in different parents), each title also
    /// shows its parent directory name.
    static func displayTitles(for windows: [VSCodeWindowEntry]) -> [String] {
        var counts: [String: Int] = [:]
        for window in windows { counts[window.displayName, default: 0] += 1 }
        return windows.map { window in
            guard counts[window.displayName, default: 0] > 1 else { return window.displayName }
            let parent = window.target.deletingLastPathComponent().lastPathComponent
            return "\(window.displayName) — \(parent)"
        }
    }

    func openWindows() throws -> [VSCodeWindowEntry] {
        let stateData: Data
        do {
            stateData = try Data(contentsOf: stateFileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return try Self.entries(stateData: stateData,
                                untitledWorkspacesDirectory: untitledWorkspacesDirectory,
                                readWorkspaceFile: { try Data(contentsOf: $0) })
    }

    /// Every window in the order VS Code saved it, which is the order the windows were
    /// created (`getWindows()` is the values of a Map filled as windows are created). A
    /// window Switch cannot target, such as a remote one, holds its place with nil.
    func pathsInCreationOrder() throws -> [String?] {
        try windowsInCreationOrder().map(\.path)
    }

    func windowsInCreationOrder() throws -> [VSCodeWindowOrder.SavedWindow] {
        let stateData: Data
        do {
            stateData = try Data(contentsOf: stateFileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return try Self.savedWindows(stateData: stateData).map { window in
            VSCodeWindowOrder.SavedWindow(
                path: try Self.entry(for: window,
                                     untitledWorkspacesDirectory: untitledWorkspacesDirectory,
                                     readWorkspaceFile: { try Data(contentsOf: $0) })?.exactPath,
                bounds: Self.savedBounds(of: window))
        }
    }

    private static func savedWindows(stateData: Data) throws -> [[String: Any]] {
        guard let root = try JSONSerialization.jsonObject(with: stateData) as? [String: Any] else {
            throw VSCodeWindowCatalogError.malformedState("root is not an object")
        }
        guard let rawWindowsState = root["windowsState"] else {
            return []
        }
        guard let windowsState = rawWindowsState as? [String: Any] else {
            throw VSCodeWindowCatalogError.malformedState("windowsState is not an object")
        }

        var windows: [[String: Any]]
        switch windowsState["openedWindows"] {
        case nil:
            windows = []
        case let opened as [[String: Any]]:
            windows = opened
        default:
            throw VSCodeWindowCatalogError.malformedState("openedWindows is not an array of objects")
        }
        if windows.isEmpty, let rawLastActive = windowsState["lastActiveWindow"] {
            guard let lastActive = rawLastActive as? [String: Any] else {
                throw VSCodeWindowCatalogError.malformedState("lastActiveWindow is not an object")
            }
            windows = [lastActive]
        }
        return windows
    }

    static func entries(stateData: Data,
                        untitledWorkspacesDirectory: URL,
                        readWorkspaceFile: (URL) throws -> Data) throws -> [VSCodeWindowEntry] {
        let windows = try savedWindows(stateData: stateData)
        var seenTargets = Set<String>()
        var result: [VSCodeWindowEntry] = []
        for window in windows {
            guard let entry = try entry(for: window,
                                        untitledWorkspacesDirectory: untitledWorkspacesDirectory,
                                        readWorkspaceFile: readWorkspaceFile) else {
                continue
            }
            if seenTargets.insert(entry.target.path).inserted {
                result.append(entry)
            }
        }
        return result.sorted { lhs, rhs in
            let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
            return order == .orderedSame ? lhs.target.path < rhs.target.path : order == .orderedAscending
        }
    }

    /// Returns nil for windows that cannot be targeted through a local file URL:
    /// empty windows, remote windows (SSH, containers, WSL), and virtual
    /// workspaces.
    private static func entry(for window: [String: Any],
                              untitledWorkspacesDirectory: URL,
                              readWorkspaceFile: (URL) throws -> Data) throws -> VSCodeWindowEntry? {
        let bounds = savedBounds(of: window)
        if let remoteAuthority = window["remoteAuthority"] {
            guard remoteAuthority is String else {
                throw VSCodeWindowCatalogError.malformedState("remoteAuthority is not a string")
            }
            return nil
        }

        let folderURI = try optionalString(window["folder"], key: "folder")
        let workspaceConfigURI: String?
        switch window["workspaceIdentifier"] {
        case nil:
            workspaceConfigURI = nil
        case let identifier as [String: Any]:
            guard let configURIPath = identifier["configURIPath"] as? String else {
                throw VSCodeWindowCatalogError.malformedState("workspaceIdentifier.configURIPath is not a string")
            }
            workspaceConfigURI = configURIPath
        default:
            throw VSCodeWindowCatalogError.malformedState("workspaceIdentifier is not an object")
        }

        switch (folderURI, workspaceConfigURI) {
        case (nil, nil):
            return nil
        case (.some, .some):
            throw VSCodeWindowCatalogError.malformedState("window has both folder and workspaceIdentifier")
        case (let folderURI?, nil):
            guard let folderURL = try localFileURL(folderURI, key: "folder") else { return nil }
            return VSCodeWindowEntry(kind: .folder,
                                     displayName: folderURL.lastPathComponent,
                                     target: folderURL,
                                     exactPath: try exactPath(ofFileURI: folderURI, key: "folder"),
                                     bounds: bounds)
        case (nil, let configURI?):
            guard let configURL = try localFileURL(configURI, key: "workspaceIdentifier.configURIPath") else {
                return nil
            }
            let exactConfigPath = try exactPath(ofFileURI: configURI, key: "workspaceIdentifier.configURIPath")
            if isInside(configURL, directory: untitledWorkspacesDirectory) {
                return VSCodeWindowEntry(kind: .untitledWorkspace,
                                         displayName: try untitledWorkspaceDisplayName(configURL: configURL,
                                                                                       readWorkspaceFile: readWorkspaceFile),
                                         target: configURL,
                                         exactPath: exactConfigPath,
                                         bounds: bounds)
            }
            let fileName = configURL.lastPathComponent
            let displayName = configURL.pathExtension == "code-workspace"
                ? configURL.deletingPathExtension().lastPathComponent
                : fileName
            return VSCodeWindowEntry(kind: .workspaceFile, displayName: displayName, target: configURL, exactPath: exactConfigPath, bounds: bounds)
        }
    }

    /// An untitled workspace is named after its first folder, which is the
    /// folder the user added first.
    private static func untitledWorkspaceDisplayName(configURL: URL,
                                                     readWorkspaceFile: (URL) throws -> Data) throws -> String {
        let path = configURL.path
        let data: Data
        do {
            data = try readWorkspaceFile(configURL)
        } catch {
            throw VSCodeWindowCatalogError.malformedWorkspace(path: path, reason: "cannot be read: \(error.localizedDescription)")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw VSCodeWindowCatalogError.malformedWorkspace(path: path, reason: "is not valid JSON")
        }
        guard let workspace = parsed as? [String: Any],
              let folders = workspace["folders"] as? [[String: Any]] else {
            throw VSCodeWindowCatalogError.malformedWorkspace(path: path, reason: "folders is not an array of objects")
        }
        guard let first = folders.first else {
            return untitledWorkspaceDisplayName
        }
        if let name = first["name"] {
            guard let name = name as? String, !name.isEmpty else {
                throw VSCodeWindowCatalogError.malformedWorkspace(path: path, reason: "folders[0].name is not a non-empty string")
            }
            return name
        }
        if let folderPath = first["path"] {
            guard let folderPath = folderPath as? String, !folderPath.isEmpty else {
                throw VSCodeWindowCatalogError.malformedWorkspace(path: path, reason: "folders[0].path is not a non-empty string")
            }
            let base = configURL.deletingLastPathComponent()
            let resolved = folderPath.hasPrefix("/")
                ? URL(fileURLWithPath: folderPath, isDirectory: true)
                : base.appendingPathComponent(folderPath, isDirectory: true)
            return resolved.standardizedFileURL.lastPathComponent
        }
        if let folderURI = first["uri"] {
            guard let folderURI = folderURI as? String,
                  let url = URL(string: folderURI),
                  !url.lastPathComponent.isEmpty else {
                throw VSCodeWindowCatalogError.malformedWorkspace(path: path, reason: "folders[0].uri is not a valid URI")
            }
            return url.lastPathComponent
        }
        throw VSCodeWindowCatalogError.malformedWorkspace(path: path, reason: "folders[0] has neither path nor uri")
    }

    private static func optionalString(_ value: Any?, key: String) throws -> String? {
        guard let value else { return nil }
        guard let string = value as? String else {
            throw VSCodeWindowCatalogError.malformedState("\(key) is not a string")
        }
        return string
    }

    /// Returns the standardized file URL, or nil if the URI uses a non-file scheme
    /// (for example a virtual workspace such as `vscode-vfs://`).
    private static func localFileURL(_ uri: String, key: String) throws -> URL? {
        guard let url = URL(string: uri), let scheme = url.scheme else {
            throw VSCodeWindowCatalogError.malformedState("\(key) is not a valid URI")
        }
        guard scheme == "file" else { return nil }
        guard url.path.hasPrefix("/") else {
            throw VSCodeWindowCatalogError.malformedState("\(key) is not an absolute file URI")
        }
        return url.standardizedFileURL
    }

    private static func savedBounds(of window: [String: Any]) -> CGRect? {
        guard let state = window["uiState"] as? [String: Any],
              let x = state["x"] as? Double, let y = state["y"] as? Double,
              let width = state["width"] as? Double, let height = state["height"] as? Double else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Percent-decodes the path of a file URI without changing its Unicode form.
    static func exactPath(ofFileURI uri: String, key: String) throws -> String {
        guard let path = URLComponents(string: uri)?.percentEncodedPath.removingPercentEncoding else {
            throw VSCodeWindowCatalogError.malformedState("\(key) is not a valid URI")
        }
        return path
    }

    private static func isInside(_ url: URL, directory: URL) -> Bool {
        let directoryPath = directory.standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return url.standardizedFileURL.path.hasPrefix(prefix)
    }
}
