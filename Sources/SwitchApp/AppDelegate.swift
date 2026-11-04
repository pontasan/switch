import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var panelController: WindowPanelController?
    private var vscodeResolver: VSCodeWindowResolver?
    private var currentSwitch: Task<Void, Never>?
    private var waitingSwitches = 0
    private var terminationObserver: NSObjectProtocol?
    private var permissionObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var shortcutMonitor: WindowShortcutMonitor?
    private var refreshAfterSwitch: (() -> Void)?
    /// macOS posts this when an application's Accessibility permission changes.
    private static let permissionChanged = Notification.Name("com.apple.accessibility.api")
    private static let permissionSettle: TimeInterval = 1
    private let vscodeLocator = VSCodeWindowLocator(opener: VSCodeCLIWindowOpener(), applicationURL: {
        let bundleIdentifier = VSCodeWindowCatalog.applicationBundleIdentifier
        guard let url = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.bundleURL else {
            throw WindowSwitchError(messages: ["Visual Studio Code is not running."])
        }
        return url
    })

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let outputPath = AccessibilityProbe.outputPath(arguments: CommandLine.arguments) {
            AccessibilityProbe.run(outputPath: outputPath)
            NSApp.terminate(nil)
            return
        }
        if let outputPath = IsolatedAppChecks.argument("--pterm-bridge-check", arguments: CommandLine.arguments),
           let socket = IsolatedAppChecks.argument("--socket", arguments: CommandLine.arguments),
           let pid = IsolatedAppChecks.argument("--pid", arguments: CommandLine.arguments).flatMap(Int32.init) {
            PtermBridgeCheck.run(outputPath: outputPath, socket: socket, processIdentifier: pid)
            NSApp.terminate(nil)
            return
        }
        if let outputPath = IsolatedAppChecks.argument("--icon-check", arguments: CommandLine.arguments) {
            Task { @MainActor in
                await IsolatedAppChecks.runIconCheck(outputPath: outputPath)
                NSApp.terminate(nil)
            }
            return
        }
        if let outputPath = IsolatedAppChecks.argument("--vscode-check", arguments: CommandLine.arguments),
           let root = IsolatedAppChecks.argument("--root", arguments: CommandLine.arguments) {
            Task { @MainActor in
                await IsolatedVSCodeCheck.run(outputPath: outputPath, root: URL(fileURLWithPath: root))
                NSApp.terminate(nil)
            }
            return
        }
        if let outputPath = IsolatedAppChecks.argument("--chrome-check", arguments: CommandLine.arguments),
           let pid = IsolatedAppChecks.argument("--pid", arguments: CommandLine.arguments).flatMap({ pid_t($0) }) {
            Task { @MainActor in
                await IsolatedAppChecks.runChromeCheck(outputPath: outputPath, pid: pid)
                NSApp.terminate(nil)
            }
            return
        }
        if let outputPath = IsolatedAppChecks.argument("--quit-key-check", arguments: CommandLine.arguments) {
            Task { @MainActor in
                await IsolatedAppChecks.runQuitKeyCheck(outputPath: outputPath)
                NSApp.terminate(nil)
            }
            return
        }
        if let outputPath = IsolatedAppChecks.argument("--shortcut-check", arguments: CommandLine.arguments) {
            Task { @MainActor in
                await IsolatedAppChecks.runShortcutCheck(outputPath: outputPath,
                                                         bundleIdentifier: IsolatedAppChecks.argument("--bundle-identifier", arguments: CommandLine.arguments),
                                                         profile: IsolatedAppChecks.argument("--profile", arguments: CommandLine.arguments))
                NSApp.terminate(nil)
            }
            return
        }
        if let outputPath = IsolatedAppChecks.argument("--real-quit-check", arguments: CommandLine.arguments) {
            Task { @MainActor in
                await IsolatedAppChecks.runRealQuitCheck(outputPath: outputPath)
                NSApp.terminate(nil)
            }
            return
        }
        if let outputPath = IsolatedAppChecks.argument("--modifier-probe", arguments: CommandLine.arguments) {
            Task { @MainActor in
                await IsolatedAppChecks.runModifierProbe(outputPath: outputPath)
                NSApp.terminate(nil)
            }
            return
        }
        if let outputPath = IsolatedAppChecks.argument("--click-probe", arguments: CommandLine.arguments) {
            Task { @MainActor in
                await IsolatedAppChecks.runClickProbe(outputPath: outputPath)
                NSApp.terminate(nil)
            }
            return
        }
        if let outputPath = IsolatedAppChecks.argument("--real-follow-check", arguments: CommandLine.arguments) {
            Task { @MainActor in
                await IsolatedAppChecks.runRealFollowCheck(outputPath: outputPath)
                NSApp.terminate(nil)
            }
            return
        }
        if let outputPath = IsolatedAppChecks.argument("--vscode-state", arguments: CommandLine.arguments) {
            IsolatedAppChecks.writeVSCodeState(outputPath: outputPath)
            NSApp.terminate(nil)
            return
        }
        if let outputPath = IsolatedAppChecks.argument("--panel-image", arguments: CommandLine.arguments) {
            PanelImage.write(to: outputPath)
            NSApp.terminate(nil)
            return
        }
        if let count = RealWindowSelfTest.fixtureWindowCount(arguments: CommandLine.arguments) {
            RealWindowSelfTest.showFixture(windowCount: count)
            return
        }
        if let outputPath = RealWindowSelfTest.outputPath(arguments: CommandLine.arguments) {
            Task { @MainActor in
                await RealWindowSelfTest.run(outputPath: outputPath)
                NSApp.terminate(nil)
            }
            return
        }
        #endif

        // After the diagnostics, which start several copies of the app on purpose.
        if SingleInstance.anotherInstanceIsRunning() {
            NSApp.terminate(nil)
            return
        }

        let panel = WindowPanelController(
            onApply: { [weak self] application, windows in self?.apply(windows, of: application) },
            onRequestPermission: { Self.requestPermission() },
            onQuit: { NSApp.terminate(nil) })
        panelController = panel
        // Almost nothing works without it, so it is asked for straight away.
        if !AXIsProcessTrusted() { Self.requestPermission() }
        let resolver = VSCodeWindowResolver(locator: vscodeLocator)
        vscodeResolver = resolver
        resolver.start()
        // Reading every application can take over a second the first time, so the panel
        // opens from the last reading and updates itself when the new one is ready.
        var latest: [ListedApplication] = []
        func latestApplications() -> [ListedApplication] { latest }
        var newestReading = 0
        func refreshApplications() {
            let start = Date()
            newestReading += 1
            let reading = newestReading
            // A slower, older reading could bring back an application that has quit.
            let show: @MainActor ([ListedApplication]) -> Void = { [weak panel] applications in
                guard reading == newestReading else { return }
                latest = applications
                if panel?.isVisible == true { panel?.update(applications: applications) }
            }
            WindowListing.load(vscodeWindows: { [resolver] in
                                   VSCodeKnownWindows(byPath: vscodeLocator.knownWindows, withoutPath: resolver.windowsWithoutPath())
                               },
                               previous: latest,
                               partial: show) { applications in
                guard reading == newestReading else { return }
                show(applications)
                vscodeLocator.forgetPaths(notIn: Set(applications.flatMap(\.windows).compactMap { window -> String? in
                    if case .vscode(let path) = window.selection { return path }
                    return nil
                }))
                let vscode = applications.first { $0.bundleIdentifier == VSCodeWindowCatalog.applicationBundleIdentifier }
                Logger(subsystem: "com.tranworks.switch", category: "timing")
                    .notice("listed \(applications.count) applications in \(Int(Date().timeIntervalSince(start) * 1000)) ms; VS Code \(vscode?.windows.count ?? 0) windows, \(vscode?.windows.filter(\.isMinimized).count ?? 0) minimized")
            }
        }
        let vscodeLocator = self.vscodeLocator
        let launchAtLogin = LaunchAtLogin(onFailure: { [weak self] in self?.present($0) })
        #if !DEBUG
        // A debug build is for checks, and must not take the place of the real one at login.
        launchAtLogin.setUpOnFirstLaunch()
        #endif
        menuBarController = MenuBarController(launchAtLogin: launchAtLogin, onClick: { [weak panel, resolver] anchor in
            guard let panel else { return }
            if panel.isVisible {
                panel.close()
                return
            }
            guard !panel.wasJustClosed else { return }
            resolver.attachIfNeeded()
            let clicked = NSApp.currentEvent?.timestamp
            panel.show(applications: latestApplications(),
                       hasPermission: AXIsProcessTrusted(),
                       frontmostName: NSWorkspace.shared.frontmostApplication?.localizedName,
                       below: anchor)
            if let clicked {
                Logger(subsystem: "com.tranworks.switch", category: "timing")
                    .notice("panel shown \(Int((ProcessInfo.processInfo.systemUptime - clicked) * 1000)) ms after the click")
            }
            refreshApplications()
        })
        refreshApplications()
        // The keys start from the window in front, which a switch has just changed.
        refreshAfterSwitch = { refreshApplications() }
        let monitor = WindowShortcutMonitor { [weak self, weak panel, resolver] command in
            guard let self, let panel else { return }
            switch command {
            case .begin, .beginGoingBack:
                guard let anchor = self.menuBarController?.anchor,
                      let front = NSWorkspace.shared.frontmostApplication else {
                    self.shortcutMonitor?.sessionEnded()
                    return
                }
                resolver.attachIfNeeded()
                panel.beginKeyboardSession(applications: Self.withFrontRefreshed(latestApplications(), front: front, known: self.vscodeLocator.knownWindows),
                                           frontmostName: front.localizedName,
                                           below: anchor,
                                           step: command == .begin ? 1 : -1)
                refreshApplications()
            case .advance:
                panel.moveKeyboardSelection(by: 1)
            case .retreat:
                panel.moveKeyboardSelection(by: -1)
            case .jump(let letter):
                panel.jumpKeyboardSelection(to: letter)
            case .commit:
                panel.commitKeyboardSelection()
            case .cancel:
                panel.cancelKeyboardSession()
            }
        }
        shortcutMonitor = monitor
        panel.onKeyboardSessionEnded = { [weak monitor] in monitor?.sessionEnded() }
        monitor.setShortcut(WindowShortcut.fromSettings())
        monitor.setLetterKeys(LetterKeys.current())
        monitor.setFrontmost(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak monitor] _ in
            MainActor.assumeIsolated { monitor?.setLetterKeys(LetterKeys.current()) }
        }
        monitor.start()
        // Changing the shortcut means going to System Settings and then leaving it, so this
        // also sees every change without anything having to look for one.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak monitor] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            monitor?.setFrontmost(application?.processIdentifier)
            monitor?.setShortcut(WindowShortcut.fromSettings())
        }
        // The next panel opens from this reading, so it has to know what was just paired.
        // This happens only when the pairing changes.
        resolver.onChange = { refreshApplications() }
        // Permission can arrive at any time, and using it should not need a relaunch.
        permissionObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.permissionChanged, object: nil, queue: .main
        ) { [weak panel, weak monitor, resolver] _ in
            // The notification can come before the new answer is available, as far as is known here,
            // so the answer is read a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.permissionSettle) {
                MainActor.assumeIsolated {
                    let trusted = AXIsProcessTrusted()
                    if trusted {
                        resolver.attachIfNeeded()
                        monitor?.start()
                    } else {
                        monitor?.stop()
                    }
                    panel?.setHasPermission(trusted)
                    refreshApplications()
                }
            }
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak panel] _ in
            MainActor.assumeIsolated {
                if panel?.isVisible == true { refreshApplications() }
            }
        }
    }

    private static func withFrontRefreshed(_ applications: [ListedApplication], front: NSRunningApplication,
                                           known: [String: ManagedWindow]) -> [ListedApplication] {
        let onScreen = FrontWindow.onScreenFrontToBack()
        return applications.map { application in
            guard application.name == front.localizedName else { return application }
            var refreshed = application
            refreshed.windows = FrontWindow.refreshed(application.windows, of: front.processIdentifier, in: onScreen) { row in
                if case .vscode(let path) = row.selection { return (known[path] as? AccessibilityWindow)?.number }
                return FrontWindow.number(of: row)
            }
            return refreshed
        }
    }

    private static func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func apply(_ windows: [ListedWindow], of application: ListedApplication) {
        guard AXIsProcessTrusted() else {
            present(WindowPanelController.permissionMessage)
            return
        }
        let screens = NSScreen.screens
        guard let primary = screens.first,
              let index = WindowLayout.screenIndex(containing: NSEvent.mouseLocation, in: screens.map(\.frame)) else {
            present("There is no screen to arrange windows on.")
            return
        }
        let area = screens[index].visibleFrame
        let columnsArea = WindowLayout.accessibilityFrame(appKitFrame: area, primaryScreenHeight: primary.frame.height)
        let locator = vscodeLocator
        waitingSwitches += 1
        let switcher = WindowSwitcher(locateVSCodeWindow: { try await locator.locate(path: $0, in: $1) },
                                      newerSelectionIsWaiting: { [weak self] in (self?.waitingSwitches ?? 0) > 1 })
        // Selections run one after another. Overlapping ones would act on each other's
        // half-finished state, and each could minimize the other's windows.
        let previous = currentSwitch
        currentSwitch = Task { @MainActor in
            await previous?.value
            defer { waitingSwitches -= 1 }
            do {
                try await switcher.apply(windows.map(\.selection), in: application.application, columnsArea: columnsArea)
            } catch {
                present(error.localizedDescription)
            }
            refreshAfterSwitch?()
        }
    }

    #if DEBUG
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        RealWindowSelfTest.askBeforeQuitting()
    }
    #endif

    /// The app has no window of its own, so it must activate to show an alert.
    private func present(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Switch"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
