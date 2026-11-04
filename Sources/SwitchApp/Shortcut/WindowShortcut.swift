import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Which letter or digit each key types on its own. A key event's own text depends on what is
/// held, Option+A being "å", and on the input method. Asking the keyboard layout about the
/// key alone, on the layout macOS uses for ASCII, gives the same answer through all of that.
enum LetterKeys {
    /// Key codes are below 128: `Events.h` has none higher.
    private static let keyCodes: Range<UInt16> = 0..<128

    /// On the main thread, because Text Input Sources requires it.
    @MainActor
    static func current() -> [Int64: Character] {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> [Int64: Character] in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return [:] }
            var letters: [Int64: Character] = [:]
            for keyCode in keyCodes {
                var deadKeys: UInt32 = 0
                var length = 0
                var text = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, text.count, &length, &text)
                guard status == noErr, length == 1, let scalar = Unicode.Scalar(text[0]), scalar.isASCII,
                      scalar.properties.isAlphabetic || scalar.properties.numericType != nil else { continue }
                letters[Int64(keyCode)] = Character(scalar).lowercased().first
            }
            return letters
        }
    }
}

/// The shortcut set in System Settings as "Move focus to next window".
struct WindowShortcut: Equatable {
    /// Where macOS keeps its shortcuts, and this one's place among them.
    static let settingsDomain = "com.apple.symbolichotkeys"
    static let settingsKey = "AppleSymbolicHotKeys"
    static let identifier = "27"
    /// Command and the Grave accent key, as Apple documents it. macOS stores a shortcut
    /// only once it has been changed, so one that is not stored has this value.
    static let standard = WindowShortcut(keyCode: 50, modifiers: CGEventFlags.maskCommand.rawValue)
    /// The modifiers that make up a shortcut. Other bits vary with the key and the device.
    static let modifierMask = CGEventFlags([.maskCommand, .maskShift, .maskControl, .maskAlternate]).rawValue

    let keyCode: Int64
    let modifiers: UInt64

    /// Nil when there is nothing to detect: the shortcut is turned off, or has no modifier
    /// and so no key to be released. A stored entry of another shape is also nil, because
    /// this is macOS's own format and is not documented.
    static func parse(_ settings: Any?) -> WindowShortcut? {
        guard let settings = settings as? [String: Any], let entry = settings[identifier] else { return standard }
        guard let entry = entry as? [String: Any],
              (entry["enabled"] as? NSNumber)?.boolValue == true,
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [NSNumber], parameters.count == 3 else { return nil }
        let modifiers = parameters[2].uint64Value & modifierMask
        guard modifiers != 0 else { return nil }
        return WindowShortcut(keyCode: parameters[1].int64Value, modifiers: modifiers)
    }

    static func fromSettings() -> WindowShortcut? {
        let domain = settingsDomain as CFString
        CFPreferencesAppSynchronize(domain)
        return parse(CFPreferencesCopyAppValue(settingsKey as CFString, domain))
    }

    func matchesExactly(_ flags: UInt64) -> Bool {
        flags & Self.modifierMask == modifiers
    }

    /// The same shortcut with Shift added goes the other way, as Apple documents for the
    /// standard one. System Settings has no entry of its own for it, so it follows this one.
    /// A shortcut that already has Shift has no such partner.
    func matchesGoingBack(_ flags: UInt64) -> Bool {
        let shift = CGEventFlags.maskShift.rawValue
        return modifiers & shift == 0 && flags & Self.modifierMask == modifiers | shift
    }

    func isHeld(_ flags: UInt64) -> Bool {
        flags & modifiers == modifiers
    }
}

/// Decides what a key event means, from the events alone. The key is taken only when macOS
/// would have nothing to switch between, and left alone otherwise.
struct WindowShortcutTracker {
    enum Event: Equatable {
        case keyDown(keyCode: Int64, flags: UInt64, isRepeat: Bool)
        case keyUp(keyCode: Int64)
        case flagsChanged(flags: UInt64)
    }

    enum Command: Equatable {
        case begin, beginGoingBack, advance, retreat, jump(Character), commit, cancel
    }

    struct Outcome: Equatable {
        var swallow = false
        var command: Command? = nil
    }

    static let escapeKeyCode: Int64 = 53
    static let downArrowKeyCode: Int64 = 125
    static let upArrowKeyCode: Int64 = 126
    /// With two windows or more, macOS switches between them itself.
    static let mostWindowsToTakeOver = 1

    var shortcut: WindowShortcut?
    var letterKeys: [Int64: Character] = [:]
    private(set) var isHolding = false
    /// A key taken when pressed is taken when released too, so that no application sees
    /// half of a key press.
    private var takenKeys: Set<Int64> = []

    /// `visibleWindowCount` is asked only when the shortcut is pressed. Nil means that
    /// this is not for Switch to handle.
    mutating func handle(_ event: Event, visibleWindowCount: () -> Int?) -> Outcome {
        switch event {
        case .keyDown(let keyCode, let flags, let isRepeat):
            if isHolding {
                if keyCode == Self.escapeKeyCode {
                    isHolding = false
                    takenKeys.insert(keyCode)
                    return Outcome(swallow: true, command: .cancel)
                }
                if keyCode == Self.downArrowKeyCode || keyCode == Self.upArrowKeyCode {
                    takenKeys.insert(keyCode)
                    return Outcome(swallow: true, command: keyCode == Self.downArrowKeyCode ? .advance : .retreat)
                }
                guard keyCode == shortcut?.keyCode else {
                    guard let letter = letterKeys[keyCode] else { return Outcome() }
                    // Holding a letter down is not asking again, unlike the keys that step.
                    takenKeys.insert(keyCode)
                    return Outcome(swallow: true, command: isRepeat ? nil : .jump(letter))
                }
                takenKeys.insert(keyCode)
                if shortcut?.matchesExactly(flags) == true { return Outcome(swallow: true, command: .advance) }
                return Outcome(swallow: true, command: shortcut?.matchesGoingBack(flags) == true ? .retreat : nil)
            }
            guard !isRepeat, let shortcut, keyCode == shortcut.keyCode else { return Outcome() }
            let goingBack = shortcut.matchesGoingBack(flags)
            guard shortcut.matchesExactly(flags) || goingBack,
                  let count = visibleWindowCount(), count <= Self.mostWindowsToTakeOver else { return Outcome() }
            isHolding = true
            takenKeys.insert(keyCode)
            return Outcome(swallow: true, command: goingBack ? .beginGoingBack : .begin)
        case .keyUp(let keyCode):
            return Outcome(swallow: takenKeys.remove(keyCode) != nil)
        case .flagsChanged(let flags):
            // Nothing is taken here: an application has to know that a modifier was released.
            guard isHolding, shortcut?.isHeld(flags) != true else { return Outcome() }
            isHolding = false
            return Outcome(command: .commit)
        }
    }

    /// The panel closed for another reason, such as a click outside it.
    mutating func sessionEnded() {
        isHolding = false
    }
}
