import AppKit
import Foundation
import os
import Security

/// pterm keeps many terminals in one window, and shows one or several of them itself. It says
/// what it has over a socket of its own, and each end checks the other's signature. Only two
/// things can be asked: what the terminals are called, and which to show.
struct PtermBridgeClient {
    static let applicationBundleIdentifier = "com.tranworks.pterm"
    private static let log = Logger(subsystem: "com.tranworks.switch", category: "pterm")
    private static let maximumReplySize = 4_194_304
    private static let maximumTerminals = 4096
    private static let maximumTextLength = 200
    /// An application can be busy for this long and still come back. Its rows stay meanwhile.
    private static let replyDeadline: TimeInterval = 3
    static let untitledTerminalTitle = "Terminal"

    struct Terminal: Equatable {
        let id: String
        let title: String
        let workspace: String
        let isDisplayed: Bool
    }

    enum Failure: Error, Equatable {
        /// No bridge, as with a version of pterm without one, or a peer that is not pterm.
        case unavailable
        /// It may yet answer. Nothing can be said about what it has.
        case noAnswer
        case refused
    }

    let socketPath: String
    /// Whether the process on this connected socket is the one expected.
    let verifyPeer: (Int32) -> Bool

    /// The real pterm, with this process identifier, in the default profile. A copy of pterm
    /// running with a profile of its own has its socket elsewhere and is listed by its window.
    static func forApplication(processIdentifier: pid_t) -> PtermBridgeClient? {
        guard let verifier = PtermPeerVerifier() else { return nil }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pterm/switch.sock").path
        return PtermBridgeClient(socketPath: path, verifyPeer: {
            verifier.isGenuine(connection: $0, processIdentifier: processIdentifier)
        })
    }

    func list() throws -> [Terminal] {
        let reply = try exchange(["op": "list"])
        guard let raw = reply["terminals"] as? [[String: Any]], raw.count <= Self.maximumTerminals else {
            throw Failure.refused
        }
        return raw.compactMap { entry in
            guard let id = (entry["id"] as? String).flatMap(UUID.init(uuidString:))?.uuidString,
                  let title = entry["title"] as? String,
                  let workspace = entry["workspace"] as? String,
                  let isDisplayed = entry["displayed"] as? Bool else { return nil }
            let shown = Self.displayText(title)
            return Terminal(id: id,
                            title: shown.isEmpty ? Self.untitledTerminalTitle : shown,
                            workspace: Self.displayText(workspace),
                            isDisplayed: isDisplayed)
        }
    }

    /// Asks pterm to show these, and returns the number of the window they are in.
    func show(terminals: [String]) throws -> Int {
        let ids = terminals.compactMap { UUID(uuidString: $0)?.uuidString }
        guard ids.count == terminals.count, !ids.isEmpty else { throw Failure.refused }
        guard let number = try exchange(["op": "show", "terminals": ids])["window_number"] as? Int else {
            throw Failure.refused
        }
        return number
    }

    /// A title is whatever a directory or a user called it, so it is only ever text to show.
    /// Controls, and the invisible marks that can make text read as something else, are removed.
    static func displayText(_ text: String) -> String {
        let hidden: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]
        let scalars = text.unicodeScalars.filter { !hidden.contains($0.properties.generalCategory) }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
            .prefixed(maximumTextLength)
    }

    private func exchange(_ request: [String: Any]) throws -> [String: Any] {
        var info = stat()
        guard lstat(socketPath, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else {
            throw Failure.unavailable
        }
        var address = sockaddr_un()
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.unavailable }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        var noSignal: Int32 = 1
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw Failure.unavailable
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: socketPath.utf8) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure.unavailable }
        // Before anything is sent or believed.
        guard verifyPeer(descriptor) else {
            Self.log.error("the process behind pterm's socket is not the expected pterm")
            throw Failure.unavailable
        }
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)
        let sent = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard sent == line.count else { throw Failure.noAnswer }

        guard let object = try JSONSerialization.jsonObject(with: try readLine(from: descriptor)) as? [String: Any] else {
            throw Failure.refused
        }
        guard object["ok"] as? Bool == true else { throw Failure.refused }
        return object
    }

    private func readLine(from descriptor: Int32) throws -> Data {
        let deadline = Date().addingTimeInterval(Self.replyDeadline)
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN {
                guard Date() < deadline else { throw Failure.noAnswer }
                continue
            }
            // Closed with nothing said: this copy of Switch was refused.
            guard count > 0 else { throw Failure.unavailable }
            reply.append(contentsOf: buffer[0..<count])
            if let end = reply.firstIndex(of: 0x0A) { return reply.prefix(upTo: end) }
            guard reply.count <= Self.maximumReplySize else { throw Failure.refused }
        }
    }
}

private extension String {
    func prefixed(_ length: Int) -> String {
        count > length ? String(prefix(length)) + "…" : self
    }
}

/// Decides from the code signature, as the kernel identifies the peer: Developer ID, the same
/// team as this copy of Switch, pterm's identifier, the hardened runtime, the expected process.
struct PtermPeerVerifier {
    private static let hardenedRuntimeFlag: UInt32 = 0x10000
    private let requirement: SecRequirement

    /// Nil for a build with no team of its own, which then has nothing to compare with.
    init?() {
        guard let team = Self.ownTeam(), Self.isPlainTeamIdentifier(team) else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(Self.requirementText(team: team) as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        self.requirement = requirement
    }

    static func requirementText(team: String) -> String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and "
            + "certificate leaf[field.1.2.840.113635.100.6.1.13] and "
            + "certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(PtermBridgeClient.applicationBundleIdentifier)\""
    }

    /// The team goes into the requirement's text, so it may hold nothing that could change its meaning.
    static func isPlainTeamIdentifier(_ team: String) -> Bool {
        !team.isEmpty && team.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }
    }

    func isGenuine(connection: Int32, processIdentifier: pid_t) -> Bool {
        var peer: pid_t = 0
        var peerLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(connection, SOL_LOCAL, LOCAL_PEERPID, &peer, &peerLength) == 0, peer == processIdentifier else {
            return false
        }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(connection, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let attributes = [kSecGuestAttributeAudit: withUnsafeBytes(of: &token) { Data($0) }] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess,
              let flags = Self.signingInformation(of: code)?[kSecCodeInfoFlags as String] as? UInt32 else {
            return false
        }
        return flags & Self.hardenedRuntimeFlag != 0
    }

    private static func ownTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return signingInformation(of: code)?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func signingInformation(of code: SecCode) -> [String: Any]? {
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else {
            return nil
        }
        return information as? [String: Any]
    }
}

/// What a choice of pterm terminals does: pterm shows them in its window, however it arranges
/// them, and that one window is what Switch then brings forward.
enum PtermSelection {
    private static let windowTimeout: TimeInterval = 2
    private static let pollNanoseconds: UInt64 = 50_000_000

    /// These wait for pterm's answer, so they do not run on the main thread.
    static func show(terminals: [String], in application: ManagedApplication) async throws -> ManagedWindow {
        guard let accessible = application as? AccessibilityApplication,
              let client = PtermBridgeClient.forApplication(processIdentifier: accessible.processIdentifier) else {
            throw WindowSwitchError(messages: ["pterm could not be reached."])
        }
        let number: Int
        do {
            number = try client.show(terminals: terminals)
        } catch PtermBridgeClient.Failure.refused {
            throw WindowSwitchError(messages: ["pterm no longer has that terminal."])
        } catch {
            throw WindowSwitchError(messages: ["pterm could not be reached."])
        }
        func window() -> ManagedWindow? {
            accessible.accessibilityWindows().first { $0.number == number }
        }
        if let found = window() { return found }
        // On another Space its window is not listed until activating goes there.
        await MainActor.run { application.activate() }
        let deadline = Date().addingTimeInterval(windowTimeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: pollNanoseconds)
            if let found = window() { return found }
        }
        throw WindowSwitchError(messages: ["pterm's window could not be found."])
    }
}
