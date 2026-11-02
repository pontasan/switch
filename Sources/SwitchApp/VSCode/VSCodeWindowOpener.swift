import Foundation

/// Asks VS Code to focus the window that has a folder or workspace open.
protocol VSCodeWindowOpening {
    func open(path: String, withApplicationAt applicationURL: URL, completion: @escaping @MainActor (Error?) -> Void)
}

enum VSCodeWindowOpenError: Error, Equatable, LocalizedError {
    case targetMissing(path: String)
    case commandFailed(status: Int32, message: String)
    case launchFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .targetMissing(let path):
            return "\(path) no longer exists."
        case .commandFailed(let status, let message):
            return "The code command exited with status \(status). \(message)"
        case .launchFailed(let code):
            return "The code command could not start. \(String(cString: strerror(code)))"
        }
    }
}

/// Focuses windows through the `code` command bundled inside the VS Code app.
///
/// `NSWorkspace.open` must not be used for this. It reaches VS Code as an
/// `open-file` event, and VS Code treats every path without a `.code-workspace`
/// extension as a file to edit. An untitled workspace's `workspace.json` would
/// open as a text tab in the last active window, and the requested window would
/// stay behind. Command line paths are resolved as workspaces by their location,
/// so the `code` command focuses the existing window for all window kinds.
///
/// `Foundation.Process` must not be used either. It converts arguments to the
/// decomposed file system form (measured), so a path VS Code stored in NFC reaches
/// it in NFD. VS Code then sees another workspace and opens a new window.
struct VSCodeCLIWindowOpener: VSCodeWindowOpening {
    /// Options placed before the path. Only tests use this, to reach a separate instance.
    var extraArguments: [String] = []

    struct Invocation: Equatable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    /// The environment is explicit so that nothing inherited by Switch can change
    /// what the command does (`VSCODE_IPC_HOOK_CLI` reroutes it to a remote CLI,
    /// and `NODE_OPTIONS` injects code). A target is always an absolute path, so
    /// it cannot be parsed as an option.
    static func invocation(path: String, applicationURL: URL, homeDirectory: String) -> Invocation {
        precondition(path.hasPrefix("/"), "VS Code target must be an absolute path")
        return Invocation(
            executable: applicationURL.appendingPathComponent("Contents/Resources/app/bin/code", isDirectory: false),
            arguments: [path],
            environment: ["HOME": homeDirectory, "PATH": "/usr/bin:/bin"]
        )
    }

    func open(path: String, withApplicationAt applicationURL: URL, completion: @escaping @MainActor (Error?) -> Void) {
        // The command would otherwise create a new file or window at a missing path.
        guard FileManager.default.fileExists(atPath: path) else {
            let error = VSCodeWindowOpenError.targetMissing(path: path)
            Task { @MainActor in completion(error) }
            return
        }

        var invocation = Self.invocation(path: path, applicationURL: applicationURL, homeDirectory: NSHomeDirectory())
        invocation = Invocation(executable: invocation.executable,
                                arguments: extraArguments + invocation.arguments,
                                environment: invocation.environment)
        let standardError = Pipe()
        let processIdentifier: pid_t
        do {
            processIdentifier = try Self.spawn(invocation, standardError: standardError)
        } catch {
            Task { @MainActor in completion(error) }
            return
        }
        try? standardError.fileHandleForWriting.close()

        DispatchQueue.global(qos: .userInitiated).async {
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            var waitStatus: Int32 = 0
            while waitpid(processIdentifier, &waitStatus, 0) == -1 && errno == EINTR {}
            let exited = (waitStatus & 0x7f) == 0
            let status = exited ? (waitStatus >> 8) & 0xff : 128 + (waitStatus & 0x7f)
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                completion(status == 0 ? nil : VSCodeWindowOpenError.commandFailed(status: status, message: message))
            }
        }
    }

    /// Passes each string's UTF-8 bytes to the child unchanged.
    private static func spawn(_ invocation: Invocation, standardError: Pipe) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, standardError.fileHandleForWriting.fileDescriptor, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors above reach the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let executable = invocation.executable.path
        let arguments = ([executable] + invocation.arguments).map { strdup($0) } + [nil]
        let environment = invocation.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            arguments.forEach { free($0) }
            environment.forEach { free($0) }
        }
        var processIdentifier: pid_t = 0
        let result = posix_spawn(&processIdentifier, executable, &fileActions, &attributes, arguments, environment)
        guard result == 0 else {
            throw VSCodeWindowOpenError.launchFailed(code: result)
        }
        return processIdentifier
    }
}
