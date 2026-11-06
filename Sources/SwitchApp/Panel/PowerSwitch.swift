import AppKit
import QuartzCore

/// Switch on or off for an application, drawn as a power switch. The system switch is drawn in
/// grey while its application is not active, which the panel never is, so on and off would
/// differ only by where the knob sits. This one is filled with the accent color when on.
final class PowerSwitch: NSControl {
    static let size = NSSize(width: 28, height: 16)
    private static let knobInset: CGFloat = 1.5
    private static let slide: TimeInterval = 0.18

    private(set) var isOn: Bool
    /// Where the knob is, from 0 (off, left) to 1 (on, right). Animated between the two.
    @objc dynamic var knobPosition: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        knobPosition = isOn ? 1 : 0
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        setAccessibilityValue(isOn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PowerSwitch is not created from an archive")
    }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "knobPosition" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    func setOn(_ on: Bool, animated: Bool) {
        isOn = on
        setAccessibilityValue(on)
        guard animated else {
            knobPosition = on ? 1 : 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slide
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().knobPosition = on ? 1 : 0
        }
    }

    /// The panel does not activate Switch, so the first click must already count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        toggle()
    }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }

    private func toggle() {
        setOn(!isOn, animated: true)
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = track.height / 2
        // Resolved here, in the view's own appearance, so light and dark each get theirs.
        let off = NSColor.labelColor.withAlphaComponent(0.16).usingColorSpace(.sRGB) ?? .gray
        let on = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        (off.blended(withFraction: knobPosition, of: on) ?? on).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let diameter = track.height - Self.knobInset * 2
        let travel = track.width - Self.knobInset * 2 - diameter
        let knob = NSRect(x: track.minX + Self.knobInset + travel * knobPosition,
                          y: track.minY + Self.knobInset, width: diameter, height: diameter)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A note above an application's windows saying that Switch is off for it: the power symbol,
/// what is off, and what that means, on a quiet rounded card.
final class SwitchedOffNotice: NSView {
    private let title = NSTextField(labelWithString: "")
    private let fill: NSColor

    init(detail: String, textWidth: CGFloat, quietTextColor: NSColor, fill: NSColor) {
        self.fill = fill
        super.init(frame: .zero)
        let symbol = NSImageView(image: NSImage(systemSymbolName: "power", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) ?? NSImage())
        symbol.contentTintColor = quietTextColor
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSTextField(wrappingLabelWithString: detail)
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.textColor = quietTextColor
        text.preferredMaxLayoutWidth = textWidth
        for view in [symbol, title, text] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            symbol.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            text.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            text.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SwitchedOffNotice is not created from an archive")
    }

    var titleText: String {
        get { title.stringValue }
        set { title.stringValue = newValue }
    }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}
