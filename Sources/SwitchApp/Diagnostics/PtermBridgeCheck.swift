#if DEBUG
import Foundation

/// Debug-only: the bridge between two really signed programs, against a copy of pterm on a
/// throwaway profile. Moves no window of anyone's, and only that copy's own view changes.
///
///   open -g -n -W Switch.app --args --pterm-bridge-check out.json --socket <path> --pid <pid>
enum PtermBridgeCheck {
    private struct Check: Encodable {
        let name: String
        let passed: Bool
        let detail: String
    }

    static func run(outputPath: String, socket: String, processIdentifier: pid_t) {
        var checks: [Check] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(Check(name: name, passed: passed, detail: detail))
        }
        func failure(_ body: () throws -> Void) -> PtermBridgeClient.Failure? {
            do { try body(); return nil } catch { return error as? PtermBridgeClient.Failure }
        }
        guard let verifier = PtermPeerVerifier() else {
            check("this build has a team to compare with", false)
            write(checks, to: outputPath)
            return
        }
        check("this build has a team to compare with", true)
        let client = PtermBridgeClient(socketPath: socket, verifyPeer: {
            verifier.isGenuine(connection: $0, processIdentifier: processIdentifier)
        })
        let wrongProcess = PtermBridgeClient(socketPath: socket, verifyPeer: {
            verifier.isGenuine(connection: $0, processIdentifier: processIdentifier + 100_000)
        })
        check("a process other than the one expected is not believed",
              failure { _ = try wrongProcess.list() } == .unavailable)

        let terminals: [PtermBridgeClient.Terminal]
        do {
            terminals = try client.list()
        } catch {
            check("pterm answers a genuine Switch", false, "\(error)")
            write(checks, to: outputPath)
            return
        }
        check("pterm answers a genuine Switch", !terminals.isEmpty, "\(terminals.count) terminals")
        check("every terminal has a title and a workspace",
              terminals.allSatisfy { !$0.title.isEmpty && !$0.workspace.isEmpty },
              terminals.map { "\($0.workspace)/\($0.title)" }.joined(separator: ", "))
        check("the overview on show leaves every terminal not displayed",
              terminals.allSatisfy { !$0.isDisplayed })

        func displayed() -> Set<String> {
            Set(((try? client.list()) ?? []).filter(\.isDisplayed).map(\.id))
        }
        guard let first = terminals.first else {
            write(checks, to: outputPath)
            return
        }
        let number = (try? client.show(terminals: [first.id])) ?? 0
        check("showing one names its window", number > 0, "\(number)")
        check("one chosen is the only one displayed", displayed() == [first.id])

        if terminals.count >= 2 {
            let chosen = terminals.prefix(2).map(\.id)
            _ = try? client.show(terminals: chosen)
            check("two chosen are split and both displayed", displayed() == Set(chosen))
        } else {
            check("two chosen are split and both displayed", false, "only one terminal")
        }
        let before = displayed()
        check("a terminal that does not exist is refused",
              failure { _ = try client.show(terminals: [UUID().uuidString]) } == .refused)
        check("a refused choice changes nothing", displayed() == before)
        let mixed = [first.id, UUID().uuidString]
        check("one bad terminal among good ones refuses them all",
              failure { _ = try client.show(terminals: mixed) } == .refused && displayed() == before)
        write(checks, to: outputPath)
    }

    private static func write(_ checks: [Check], to path: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(checks) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
