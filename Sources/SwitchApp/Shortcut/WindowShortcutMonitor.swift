import AppKit
import os

/// Watches the keyboard through an event tap. Only a tap can leave a key to macOS at one
/// moment and take it at another: a global monitor cannot stop an event, and a registered
/// hot key always takes it.
///
/// Every key press in every application passes through here, and macOS turns off a tap that
/// answers too slowly, so it has a thread of its own and never waits for the main thread.
final class WindowShortcutMonitor: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.tranworks.switch", category: "shortcut")

    private let lock = NSLock()
    private var tracker = WindowShortcutTracker()
    private var frontmost: pid_t?
    private var tap: CFMachPort?
    private let onCommand: @MainActor (WindowShortcutTracker.Command) -> Void

    init(onCommand: @escaping @MainActor (WindowShortcutTracker.Command) -> Void) {
        self.onCommand = onCommand
    }

    deinit {
        stop()
    }

    func setShortcut(_ shortcut: WindowShortcut?) {
        lock.withLock { tracker.shortcut = shortcut }
    }

    func setLetterKeys(_ letterKeys: [Int64: Character]) {
        lock.withLock { tracker.letterKeys = letterKeys }
    }

    func setFrontmost(_ processIdentifier: pid_t?) {
        lock.withLock { frontmost = processIdentifier }
    }

    func sessionEnded() {
        lock.withLock { tracker.sessionEnded() }
    }

    var isRunning: Bool { lock.withLock { tap != nil } }

    /// Needs Accessibility permission. Without it macOS would hand out a tap that gets no keys.
    func start() {
        guard AXIsProcessTrusted(), !isRunning else { return }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: Self.callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Self.log.error("the event tap could not be created")
            return
        }
        lock.withLock { self.tap = tap }
        let thread = Thread {
            // Ends once the tap is invalidated, which takes its source off this run loop.
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Switch event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        let tap: CFMachPort? = lock.withLock {
            tracker.sessionEnded()
            defer { self.tap = nil }
            return self.tap
        }
        if let tap { CFMachPortInvalidate(tap) }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<WindowShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        return monitor.handle(type, event) ? nil : Unmanaged.passUnretained(event)
    }

    /// True when the event is taken.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let flags = event.flags.rawValue
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .keyDown:
            return handle(.keyDown(keyCode: keyCode,
                                   flags: flags,
                                   isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0))
        case .keyUp:
            return handle(.keyUp(keyCode: keyCode))
        case .flagsChanged:
            return handle(.flagsChanged(flags: flags))
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            Self.log.notice("the event tap was turned off, and is being turned on again")
            if let tap = lock.withLock({ self.tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            // A modifier may have been released while nothing was listening.
            _ = handle(.flagsChanged(flags: CGEventSource.flagsState(.combinedSessionState).rawValue))
            return false
        default:
            return false
        }
    }

    private func handle(_ event: WindowShortcutTracker.Event) -> Bool {
        let outcome: WindowShortcutTracker.Outcome = lock.withLock {
            tracker.handle(event) {
                guard let frontmost, frontmost != ProcessInfo.processInfo.processIdentifier else { return nil }
                return FrontWindow.visibleWindowCount(of: frontmost, in: FrontWindow.visibleOnScreen())
            }
        }
        if let command = outcome.command {
            let onCommand = self.onCommand
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onCommand(command) }
            }
        }
        return outcome.swallow
    }
}
