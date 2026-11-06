import AppKit
import Carbon.HIToolbox
import os

/// Watches for the shortcut through hot keys registered with macOS: the shortcut, and the
/// same with Shift for going back. While it is held the panel is the key window and takes
/// the arrows, the letters and Escape itself, so nothing else is registered.
///
/// A hot key reaches Switch while another application has turned on Secure Event Input,
/// when an event tap gets no key at all (measured on 2026-11-06 with Google Chrome's sign-in
/// page). Releasing a modifier is not a hot key, so while the shortcut is held its state is
/// read from the window server, which also works through Secure Event Input (measured).
@MainActor
final class WindowShortcutMonitor {
    private static let log = Logger(subsystem: "com.tranworks.switch", category: "shortcut")
    /// "SWCH", so that only Switch's own hot keys are handled here.
    private static let signature: OSType = 0x5357_4348
    /// Often enough that letting go chooses at once, and only while the shortcut is held.
    private static let modifierPollInterval: TimeInterval = 0.015

    private var tracker = WindowShortcutTracker()
    private var handler: EventHandlerRef?
    private var registered: [UInt32: (key: WindowShortcutTracker.Key, ref: EventHotKeyRef)] = [:]
    private var nextID: UInt32 = 1
    private var modifierPoll: Timer?
    private let onCommand: (WindowShortcutTracker.Command) -> Void

    init(onCommand: @escaping (WindowShortcutTracker.Command) -> Void) {
        self.onCommand = onCommand
    }

    var isRunning: Bool { handler != nil }

    /// Registers the shortcut again only when it has changed, since this is asked each time
    /// another application comes to the front.
    func setShortcut(_ shortcut: WindowShortcut?) {
        guard shortcut != tracker.shortcut else { return }
        tracker.shortcut = shortcut
        guard isRunning else { return }
        sessionEnded()
        unregisterAll()
        registerShortcut()
    }

    /// The panel closed for another reason, such as Escape or a click outside it.
    func sessionEnded() {
        tracker.sessionEnded()
        stopReadingModifiers()
    }

    /// Needs Accessibility permission, as switching does. Without it the panel could only say so.
    func start() {
        guard AXIsProcessTrusted(), !isRunning else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), Self.callback, 1, &type,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            Self.log.error("the hot key handler could not be installed: \(status)")
            handler = nil
            return
        }
        registerShortcut()
    }

    func stop() {
        sessionEnded()
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private static let callback: EventHandlerUPP = { _, event, userInfo in
        guard let event, let userInfo else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        guard status == noErr, hotKeyID.signature == WindowShortcutMonitor.signature else { return OSStatus(eventNotHandledErr) }
        let monitor = Unmanaged<WindowShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        // Carbon calls this on the main thread, from the application's event loop.
        MainActor.assumeIsolated { monitor.pressed(id: hotKeyID.id) }
        return noErr
    }

    private func pressed(id: UInt32) {
        guard let key = registered[id]?.key else { return }
        apply(tracker.handle(.pressed(key)))
    }

    private func apply(_ command: WindowShortcutTracker.Command?) {
        guard let command else { return }
        switch command {
        case .begin, .beginGoingBack:
            startReadingModifiers()
        case .commit:
            stopReadingModifiers()
        case .advance, .retreat:
            break
        }
        onCommand(command)
    }

    private func registerShortcut() {
        guard let shortcut = tracker.shortcut else { return }
        register(.shortcut, keyCode: UInt32(shortcut.keyCode), modifiers: shortcut.modifiers)
        if let back = shortcut.goingBack {
            register(.shortcutGoingBack, keyCode: UInt32(back.keyCode), modifiers: back.modifiers)
        }
    }

    private func startReadingModifiers() {
        guard modifierPoll == nil else { return }
        let timer = Timer(timeInterval: Self.modifierPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readModifiers() }
        }
        // Common modes, so that a menu being tracked does not hold the release back.
        RunLoop.main.add(timer, forMode: .common)
        modifierPoll = timer
    }

    private func readModifiers() {
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        apply(tracker.handle(.modifiersChanged(flags: flags)))
    }

    private func stopReadingModifiers() {
        modifierPoll?.invalidate()
        modifierPoll = nil
    }

    private func register(_ key: WindowShortcutTracker.Key, keyCode: UInt32, modifiers: UInt64) {
        let id = nextID
        nextID &+= 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, WindowShortcut.carbonModifiers(modifiers), EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Self.log.error("the hot key \(keyCode) could not be registered: \(status)")
            return
        }
        registered[id] = (key, ref)
    }

    private func unregisterAll() {
        for (_, entry) in registered { UnregisterEventHotKey(entry.ref) }
        registered = [:]
    }
}
