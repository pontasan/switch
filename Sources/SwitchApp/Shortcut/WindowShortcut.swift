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

/// The shortcut set in System Settings as "Move focus to next window". Switch registers it as
/// a hot key of its own, which reaches Switch ahead of macOS (measured) and also while another
/// application has turned on Secure Event Input, when no event tap gets a key (measured).
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

    /// The same shortcut with Shift added goes the other way, as Apple documents for the
    /// standard one. System Settings has no entry of its own for it, so it follows this one.
    /// A shortcut that already has Shift has no such partner.
    var goingBack: WindowShortcut? {
        let shift = CGEventFlags.maskShift.rawValue
        guard modifiers & shift == 0 else { return nil }
        return WindowShortcut(keyCode: keyCode, modifiers: modifiers | shift)
    }

    func isHeld(_ flags: UInt64) -> Bool {
        flags & modifiers == modifiers
    }

    /// The same modifiers as Carbon's hot keys name them.
    static func carbonModifiers(_ flags: UInt64) -> UInt32 {
        let pairs: [(CGEventFlags, Int)] = [(.maskCommand, cmdKey), (.maskAlternate, optionKey),
                                             (.maskControl, controlKey), (.maskShift, shiftKey)]
        return pairs.reduce(UInt32(0)) { flags & $1.0.rawValue != 0 ? $0 | UInt32($1.1) : $0 }
    }
}

/// Decides what the registered hot keys mean. The shortcut always opens the panel, and the
/// session ends when one of its modifiers is let go. While it is held, the panel is the key
/// window and takes the arrows, the letters and Escape itself.
struct WindowShortcutTracker {
    /// What a hot key stands for.
    enum Key: Hashable {
        case shortcut, shortcutGoingBack
    }

    enum Event: Equatable {
        case pressed(Key)
        case modifiersChanged(flags: UInt64)
    }

    enum Command: Equatable {
        case begin, beginGoingBack, advance, retreat, commit
    }

    var shortcut: WindowShortcut?
    private(set) var isHolding = false

    mutating func handle(_ event: Event) -> Command? {
        switch event {
        case .pressed(let key):
            let back = key == .shortcutGoingBack
            if isHolding { return back ? .retreat : .advance }
            guard shortcut != nil else { return nil }
            isHolding = true
            return back ? .beginGoingBack : .begin
        case .modifiersChanged(let flags):
            guard isHolding, shortcut?.isHeld(flags) != true else { return nil }
            isHolding = false
            return .commit
        }
    }

    /// The panel closed for another reason, such as Escape or a click outside it.
    mutating func sessionEnded() {
        isHolding = false
    }
}
