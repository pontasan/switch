import AppKit

/// Windows chosen with Shift+click, in the order they were clicked. That order
/// becomes the left-to-right order on screen.
struct WindowSelection: Equatable {
    private(set) var rows: [Int] = []

    mutating func toggle(_ row: Int) {
        if let index = rows.firstIndex(of: row) {
            rows.remove(at: index)
        } else {
            rows.append(row)
        }
    }

    mutating func clear() {
        rows = []
    }

    func order(of row: Int) -> Int? {
        rows.firstIndex(of: row).map { $0 + 1 }
    }
}

/// The chosen application's row: a quiet rounded shape, as in a macOS sidebar.
private final class ApplicationRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// The first window with no local path has a line above it, parting it from the windows
/// known by path.
private final class SeparatedRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        WindowPanelController.lineColor.setFill()
        let y = bounds.minY + (WindowPanelController.separatorHeight - 1) / 2
        NSRect(x: bounds.minX + 6, y: y, width: bounds.width - 12, height: 1).fill()
    }
}

/// The row the switching keys are on. The band covers the window's own part of the row, not
/// the heading or the line above it.
private final class KeyboardRowView: NSTableRowView {
    private let hasLine: Bool

    init(hasLine: Bool) {
        self.hasLine = hasLine
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeyboardRowView is not created from an archive")
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if hasLine {
            WindowPanelController.lineColor.setFill()
            let y = bounds.minY + (WindowPanelController.separatorHeight - 1) / 2
            NSRect(x: bounds.minX + 6, y: y, width: bounds.width - 12, height: 1).fill()
        }
        NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
        let band = NSRect(x: bounds.minX, y: bounds.maxY - WindowPanelController.rowHeight, width: bounds.width, height: WindowPanelController.rowHeight)
        NSBezierPath(roundedRect: band.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

/// The window list, which joins the pinned windows the shortcut goes round with a line that
/// comes back to the top: from the line on the left a branch goes to each pin, and the top
/// branch ends in an arrowhead, so the last pinned window is seen to lead to the first.
final class PinRingTableView: NSTableView {
    /// The rows joined, in order. Nil or fewer than two draws nothing.
    var ringRows: () -> [Int]? = { nil }
    /// Where the pin's center is from the row's leading edge, and the line's place left of it.
    static let pinCenterX: CGFloat = 15
    static let laneX: CGFloat = 4.5
    private static let branchEndX: CGFloat = 9.5
    private static let corner: CGFloat = 3

    /// The pins' centers, which the line runs past.
    func ringPoints() -> [NSPoint] {
        guard let rows = ringRows(), rows.count >= 2 else { return [] }
        return rows.filter { $0 < numberOfRows }.map { row in
            let rect = self.rect(ofRow: row)
            // The window's own part is the bottom of a row that has a heading above it.
            return NSPoint(x: Self.pinCenterX, y: rect.maxY - WindowPanelController.rowHeight / 2)
        }
    }

    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        let points = ringPoints()
        guard let first = points.first, let last = points.last, points.count >= 2 else { return }
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        // The lane, with rounded turns into the first and last branches.
        let lane = Self.laneX, end = Self.branchEndX, corner = Self.corner
        path.move(to: NSPoint(x: end, y: first.y))
        path.line(to: NSPoint(x: lane + corner, y: first.y))
        path.curve(to: NSPoint(x: lane, y: first.y + corner), controlPoint1: NSPoint(x: lane, y: first.y), controlPoint2: NSPoint(x: lane, y: first.y))
        path.line(to: NSPoint(x: lane, y: last.y - corner))
        path.curve(to: NSPoint(x: lane + corner, y: last.y), controlPoint1: NSPoint(x: lane, y: last.y), controlPoint2: NSPoint(x: lane, y: last.y))
        path.line(to: NSPoint(x: end, y: last.y))
        for point in points.dropFirst().dropLast() {
            path.move(to: NSPoint(x: lane, y: point.y))
            path.line(to: NSPoint(x: end, y: point.y))
        }
        // Orange, apart from the blue of the pins and of the windows on show (the user chose it).
        let color = NSColor.systemOrange
        color.setStroke()
        path.stroke()
        // Back into the first pin.
        let head = NSBezierPath()
        head.move(to: NSPoint(x: end + 1.5, y: first.y))
        head.line(to: NSPoint(x: end - 2, y: first.y - 2.5))
        head.line(to: NSPoint(x: end - 2, y: first.y + 2.5))
        head.close()
        color.setFill()
        head.fill()
    }
}

/// A window's place in a Shift+click selection: its number in a filled circle, which is
/// also where it will land from the left.
final class OrderBadge: NSView {
    static let side: CGFloat = 18
    let number: Int?

    init(number: Int?) {
        self.number = number
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.side).isActive = true
        heightAnchor.constraint(equalToConstant: Self.side).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OrderBadge is not created from an archive")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let number else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        let text = NSAttributedString(string: String(number), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

/// A panel that takes key focus without activating Switch, so the frontmost
/// application stays as it is until a window is chosen.
private final class KeyablePanel: NSPanel {
    var onFlagsChanged: ((NSEvent) -> Void)?
    var onCancel: (() -> Void)?
    var onDeleteKey: (() -> Void)?
    /// Asked first about every key pressed. True when it was taken.
    var onKeyDown: ((NSEvent) -> Bool)?

    /// The delete key above Return, and the forward delete key.
    private static let deleteKeyCodes: Set<UInt16> = [51, 117]

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            onFlagsChanged?(event)
        }
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        if event.type == .keyDown,
           Self.deleteKeyCodes.contains(event.keyCode),
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            // Quitting moves the choice to the next application, so a held key
            // must not go on to quit that one as well.
            if !event.isARepeat { onDeleteKey?() }
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// An application's row: its power switch, then its icon, name and number of windows. Off,
/// the icon loses its color as well as its strength, so the row reads as switched off and not
/// merely as quieter. It changes in place, so the knob is seen to slide.
private final class ApplicationCell: NSView {
    let power: PowerSwitch
    private let icon = NSImageView()
    private let name: NSTextField
    private let count: NSTextField
    private let colorIcon: NSImage
    private let quietTextColor: NSColor
    private let switchedOffTextColor: NSColor
    private lazy var greyIcon = WindowPanelController.switchedOffIcon(colorIcon)
    private static let switchedOffIconAlpha: CGFloat = 0.5

    init(application: ListedApplication, quietTextColor: NSColor, switchedOffTextColor: NSColor) {
        colorIcon = application.icon ?? NSImage()
        self.quietTextColor = quietTextColor
        self.switchedOffTextColor = switchedOffTextColor
        power = PowerSwitch(isOn: true)
        power.toolTip = "Switch for \(application.name)"
        power.setAccessibilityLabel("Switch for \(application.name)")
        // Rows move when an application is turned on or off, so the switch says whose it is.
        power.identifier = NSUserInterfaceItemIdentifier(application.identifier)
        name = NSTextField(labelWithString: application.name)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        count = NSTextField(labelWithString: String(application.windows.count))
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.setContentHuggingPriority(.required, for: .horizontal)
        super.init(frame: .zero)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        // What is done to the application, then a little apart, what it is.
        let stack = NSStackView(views: [power, icon, name, count])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.setCustomSpacing(10, after: power)
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ApplicationCell is not created from an archive")
    }

    func show(enabled: Bool, animated: Bool) {
        if power.isOn != enabled { power.setOn(enabled, animated: animated) }
        icon.image = enabled ? colorIcon : greyIcon
        name.textColor = enabled ? .labelColor : switchedOffTextColor
        count.textColor = enabled ? quietTextColor : switchedOffTextColor
        let alpha = enabled ? 1 : Self.switchedOffIconAlpha
        if animated {
            icon.alphaValue = enabled ? Self.switchedOffIconAlpha : 1
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; icon.animator().alphaValue = alpha }
        } else {
            icon.alphaValue = alpha
        }
    }
}

/// The window list: applications on the left, the chosen application's windows on
/// the right. Only one application's windows are ever on screen, so windows of
/// different applications cannot be selected together.
@MainActor
final class WindowPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let hint = "Click: show one window   Shift+click: show several   Delete: quit the application"
    static let permissionMessage = "Switch needs Accessibility permission to list and arrange windows."
    static let rowHeight: CGFloat = 24
    /// The extra height of the row that has the line above it.
    static let separatorHeight: CGFloat = 9
    /// The extra height of a row that has a section heading above it.
    static let sectionHeadingHeight: CGFloat = 18
    static let workspacesHeading = "Workspaces"
    static let otherWindowsHeading = "Other Windows"
    private static let contentWidth: CGFloat = 576
    private static let applicationsWidth: CGFloat = 220
    private static let reopenGuard: TimeInterval = 0.4
    /// How long after a request a loss of focus can be that request's doing.
    private static let quitWindow: TimeInterval = 10
    private static let quitChecks = 10
    private static let questionChecks = 60
    private static let quitCheckNanoseconds: UInt64 = 50_000_000

    private let panel: KeyablePanel
    private let applicationsTable = NSTableView()
    private let windowsTable = PinRingTableView()
    private let problemLabel = NSTextField(wrappingLabelWithString: "")
    private let permissionBar = NSStackView()
    private let content = NSStackView()
    private let lists = NSStackView()
    private let applicationsScroll: NSScrollView
    private let windowsScroll: NSScrollView
    /// The windows and, above them, what is said when Switch is off for their application.
    private let windowsColumn = NSStackView()
    private let disabledNotice: SwitchedOffNotice
    private let onApply: (ListedApplication, [ListedWindow]) -> Void
    private let onRequestPermission: () -> Void
    private let pins: PinnedWindows
    private let disabled: DisabledApplications
    private let centersPanel: () -> Bool
    private let settingsMenu: (() -> NSMenu)?
    private let settingsButton = NSButton()

    private(set) var applications: [ListedApplication] = []
    /// The list as it was read. Unpinning a row puts it back where this has it.
    private var listedApplications: [ListedApplication] = []
    private var lastClosed: Date?
    private var anchor = NSRect.zero
    private(set) var selectedApplication: Int?
    private(set) var selection = WindowSelection()
    /// What should be chosen while the user has not chosen anything. The first list can
    /// be older than an application just started, so the update may be the first to have it.
    private var frontmostNameWhenOpened: String?
    private var isChoosingForTheUser = false
    private var isMovingRows = false
    private var quitting: (application: ManagedApplication, requested: Date)?
    /// Open from the switching keys, which are still held.
    private(set) var isKeyboardSession = false
    private(set) var keyboardRow: Int?
    private var hasMovedKeyboardRow = false
    /// Which way the keys started, for working out the first row again from a new reading.
    private var keyboardStep = 1
    /// The letter that last moved the row. The same one again goes on to the next match.
    private var lastKeyboardLetter: Character?
    var onKeyboardSessionEnded: (() -> Void)?
    /// Switch was turned on or off for an application.
    var onEnabledChanged: (() -> Void)?
    /// Which letter or digit each key types on its own, for going to the rows starting with it.
    var letterKeys: [Int64: Character] = [:]

    init(onApply: @escaping (ListedApplication, [ListedWindow]) -> Void,
         onRequestPermission: @escaping () -> Void,
         pins: PinnedWindows? = nil,
         disabled: DisabledApplications? = nil,
         centersPanel: @escaping () -> Bool = { false },
         settingsMenu: (() -> NSMenu)? = nil) {
        self.settingsMenu = settingsMenu
        self.pins = pins ?? PinnedWindows()
        self.disabled = disabled ?? DisabledApplications()
        self.centersPanel = centersPanel
        self.onApply = onApply
        self.onRequestPermission = onRequestPermission
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
                             styleMask: Self.panelStyle,
                             backing: .buffered,
                             defer: true)
        applicationsScroll = Self.scrollView(for: applicationsTable, identifier: "application")
        windowsScroll = Self.scrollView(for: windowsTable, identifier: "window")
        disabledNotice = SwitchedOffNotice(detail: Self.disabledDetail, textWidth: Self.disabledNoticeTextWidth,
                                           quietTextColor: Self.quietTextColor, fill: Self.noticeFillColor)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onFlagsChanged = { [weak self] event in
            if !event.modifierFlags.contains(.shift) { self?.shiftReleased() }
        }
        panel.onCancel = { [weak self] in self?.close() }
        panel.onDeleteKey = { [weak self] in self?.quitChosenApplication() }
        panel.onKeyDown = { [weak self] event in self?.takeKeyboardSessionKey(event) ?? false }
        buildContent()
    }

    /// A title bar has a band of its own, which shows through glass.
    private static var panelStyle: NSWindow.StyleMask {
        if #available(macOS 26, *) { return [.borderless, .nonactivatingPanel] }
        return [.titled, .fullSizeContentView, .nonactivatingPanel]
    }

    var isVisible: Bool { panel.isVisible }

    func show(applications: [ListedApplication], hasPermission: Bool, frontmostName: String?, below anchor: NSRect) {
        reload(applications: applications, hasPermission: hasPermission, frontmostName: frontmostName)
        self.anchor = anchor
        placePanel()
        panel.makeKeyAndOrderFront(nil)
    }

    /// The list is shown at once from the last reading, and this brings it up to date
    /// a moment later without losing what the user has already done in the panel.
    func update(applications: [ListedApplication]) {
        let previousIdentifier = currentApplication?.identifier
        // Rows are selected by position, and a window that gained a path moves to another.
        let previousRows = currentApplication?.windows.map(\.rowIdentity)
        let previousSelection = selection
        let previousIndex = selectedApplication
        let previousKeyboardWindow = keyboardWindowIdentity()
        listedApplications = applications
        self.applications = arranged(applications)
        applicationsTable.reloadData()
        let list = self.applications
        // When the chosen application has quit, the one that took its row is chosen.
        let frontmostIndex = frontmostNameWhenOpened.flatMap { name in list.firstIndex { $0.name == name } }
        let index: Int?
        if isKeyboardSession, frontmostNameWhenOpened != nil {
            // The keys belong to the application in front, and never to the next one along.
            index = frontmostIndex
        } else {
            index = frontmostIndex
                ?? list.firstIndex { $0.identifier == previousIdentifier }
                ?? (list.isEmpty ? nil : min(previousIndex ?? 0, list.count - 1))
        }
        chooseApplication(index)
        if let index {
            chooseRowForTheUser(index)
            if list[index].identifier == previousIdentifier, list[index].windows.map(\.rowIdentity) == previousRows {
                selection = previousSelection
                windowsTable.reloadData()
            }
        } else if isKeyboardSession {
            clearApplicationRowForTheUser()
        }
        if isKeyboardSession { restoreKeyboardRow(previousKeyboardWindow, previousApplication: previousIdentifier) }
    }

    /// A window that stays stays chosen. Until the keys have moved, the row follows from
    /// what is in front, which the new reading may say better.
    private func restoreKeyboardRow(_ previous: (key: String, nth: Int)?, previousApplication: String?) {
        guard let application = currentApplication else {
            keyboardRow = nil
            hasMovedKeyboardRow = false
            return
        }
        guard hasMovedKeyboardRow, let previous, application.identifier == previousApplication else {
            keyboardRow = Self.nextKeyboardRow(after: nil, in: application.windows, step: keyboardStep, among: pinnedRing)
            hasMovedKeyboardRow = false
            windowsTable.reloadData()
            return
        }
        let matches = application.windows.indices.filter { application.windows[$0].pinKey == previous.key }
        if matches.indices.contains(previous.nth) {
            keyboardRow = matches[previous.nth]
        } else {
            keyboardRow = Self.nextKeyboardRow(after: nil, in: application.windows, step: keyboardStep, among: pinnedRing)
            hasMovedKeyboardRow = false
        }
        windowsTable.reloadData()
    }

    private func keyboardWindowIdentity() -> (key: String, nth: Int)? {
        guard let windows = currentApplication?.windows, let row = keyboardRow, windows.indices.contains(row) else { return nil }
        let key = windows[row].pinKey
        return (key, windows[..<row].filter { $0.pinKey == key }.count)
    }

    private func placePanel() {
        let anchorPoint = NSPoint(x: anchor.midX, y: anchor.midY)
        let screens = NSScreen.screens
        guard let index = WindowLayout.screenIndex(containing: anchorPoint, in: screens.map(\.frame)) else { return }
        let screen = screens[index]
        let width = panel.frame.width
        let frame = centersPanel()
            ? Self.centeredPanelFrame(width: width, contentHeight: contentHeight(), screen: screen.frame, visible: screen.visibleFrame)
            : Self.panelFrameBelow(anchor: anchor, width: width, contentHeight: contentHeight(), visible: screen.visibleFrame)
        panel.setFrame(frame, display: true)
    }

    static func panelFrameBelow(anchor: NSRect, width: CGFloat, contentHeight: CGFloat, visible: NSRect) -> NSRect {
        let top = min(anchor.minY, visible.maxY)
        let height = panelHeight(contentHeight: contentHeight, available: top - visible.minY)
        let x = min(anchor.midX - width / 2, visible.maxX - width)
        return NSRect(x: max(visible.minX, x), y: top - height, width: width, height: height)
    }

    /// In the center of the display itself, moved only as far as it takes to stay clear of
    /// the menu bar and the Dock.
    static func centeredPanelFrame(width: CGFloat, contentHeight: CGFloat, screen: NSRect, visible: NSRect) -> NSRect {
        let height = panelHeight(contentHeight: contentHeight, available: visible.height)
        let x = min(max((screen.midX - width / 2).rounded(), visible.minX), visible.maxX - width)
        let y = min(max((screen.midY - height / 2).rounded(), visible.minY), visible.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// As tall as what is on show needs, so that scrolling appears only when the
    /// screen itself is too short.
    static func panelHeight(contentHeight: CGFloat, available: CGFloat) -> CGFloat {
        min(contentHeight, available)
    }

    private func contentHeight() -> CGFloat {
        // At least one row, so that an empty list still looks like a list.
        let notice = disabledNotice.isHidden ? 0 : disabledNotice.fittingSize.height + windowsColumn.spacing
        let rows = max(CGFloat(applications.count) * Self.rowHeight, windowRowsHeight + notice, Self.rowHeight)
        let others = content.arrangedSubviews.filter { $0 !== lists && !$0.isHidden }
        let othersHeight = others.reduce(CGFloat(0)) { $0 + $1.fittingSize.height }
        return rows
            + othersHeight
            + CGFloat(others.count) * content.spacing
            + content.edgeInsets.top + content.edgeInsets.bottom
    }

    private var windowRowsHeight: CGFloat {
        let count = currentApplication?.windows.count ?? 0
        return (0..<count).reduce(CGFloat(count) * Self.rowHeight) { $0 + extraHeight(ofRow: $1) }
    }

    /// The heading above this row, when the list has both kinds of window. A list of one
    /// kind has nothing to tell apart.
    func sectionHeading(forRow row: Int) -> String? {
        if let group = currentApplication?.windows[row].group {
            return startsGroup(row: row) ? group : nil
        }
        guard let separatedRow else { return nil }
        if row == 0 { return Self.workspacesHeading }
        return row == separatedRow ? Self.otherWindowsHeading : nil
    }

    /// What this row has above the window itself, which is not part of the window.
    private func extraHeight(ofRow row: Int) -> CGFloat {
        (hasLineAbove(row: row) ? Self.separatorHeight : 0) + (sectionHeading(forRow: row) == nil ? 0 : Self.sectionHeadingHeight)
    }

    /// The row a click at this height belongs to. A heading and a line choose nothing.
    func windowRow(clickedRow row: Int, offsetFromRowTop offset: CGFloat) -> Int? {
        guard row >= 0, offset >= extraHeight(ofRow: row) else { return nil }
        return row
    }

    private func startsGroup(row: Int) -> Bool {
        guard let windows = currentApplication?.windows else { return false }
        return row == 0 || windows[row - 1].group != windows[row].group
    }

    private func hasLineAbove(row: Int) -> Bool {
        if currentApplication?.windows[row].group != nil { return row > 0 && startsGroup(row: row) }
        return row == separatedRow
    }

    /// The first window with no path, when windows with a path are above it.
    private var separatedRow: Int? {
        guard let windows = currentApplication?.windows,
              let row = windows.firstIndex(where: \.isWithoutPath), row > 0 else { return nil }
        return row
    }

    /// Permission was given or taken away while the panel may be on show.
    func setHasPermission(_ hasPermission: Bool) {
        permissionBar.isHidden = hasPermission
        if panel.isVisible { placePanel() }
    }

    var isAskingForPermissionForTesting: Bool { !permissionBar.isHidden }
    var isShowingSwitchedOffForTesting: Bool { !disabledNotice.isHidden }

    func reload(applications: [ListedApplication], hasPermission: Bool, frontmostName: String?) {
        listedApplications = applications
        self.applications = arranged(applications)
        permissionBar.isHidden = hasPermission
        applicationsTable.reloadData()
        let list = self.applications
        frontmostNameWhenOpened = frontmostName
        let frontmostIndex = list.firstIndex { $0.name == frontmostName }
        let initial = frontmostIndex ?? (isKeyboardSession || list.isEmpty ? nil : 0)
        chooseApplication(initial)
        if let initial {
            chooseRowForTheUser(initial)
        } else if isKeyboardSession {
            clearApplicationRowForTheUser()
        }
    }

    private func chooseRowForTheUser(_ row: Int) {
        isChoosingForTheUser = true
        applicationsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isChoosingForTheUser = false
    }

    private func clearApplicationRowForTheUser() {
        isChoosingForTheUser = true
        applicationsTable.deselectAll(nil)
        isChoosingForTheUser = false
    }

    func close() {
        quitting = nil
        panel.orderOut(nil)
        keyboardRow = nil
        hasMovedKeyboardRow = false
        lastKeyboardLetter = nil
        if isKeyboardSession {
            isKeyboardSession = false
            onKeyboardSessionEnded?()
        }
    }

    // MARK: The switching keys

    /// The switching keys were pressed where macOS has nothing to switch between. The panel
    /// is the same one, with the row after the window in front already chosen.
    func beginKeyboardSession(applications: [ListedApplication], frontmostName: String?, below anchor: NSRect, step: Int = 1) {
        close()
        isKeyboardSession = true
        show(applications: applications, hasPermission: true, frontmostName: frontmostName, below: anchor)
        keyboardStep = step
        keyboardRow = currentApplication.flatMap { Self.nextKeyboardRow(after: nil, in: $0.windows, step: step, among: pinnedRing) }
        windowsTable.reloadData()
    }

    static let downArrowKeyCode: UInt16 = 125
    static let upArrowKeyCode: UInt16 = 126

    /// While the shortcut is held the panel is the key window, so the arrows and the letters
    /// come here as they are typed (measured: a letter reached the panel, not a hot key).
    /// Escape closes the panel as it always does.
    func takeKeyboardSessionKey(_ event: NSEvent) -> Bool {
        guard isKeyboardSession else { return false }
        switch event.keyCode {
        case Self.downArrowKeyCode:
            moveKeyboardSelection(by: 1, followingPins: false)
            return true
        case Self.upArrowKeyCode:
            moveKeyboardSelection(by: -1, followingPins: false)
            return true
        default:
            guard let letter = letterKeys[Int64(event.keyCode)] else { return false }
            // Holding a letter down is not asking again, unlike the keys that step.
            if !event.isARepeat { jumpKeyboardSelection(to: letter) }
            return true
        }
    }

    /// One row down the list, or up it for a negative step, going round. The shortcut goes
    /// round the pinned windows when there are two or more of them; the arrows go everywhere.
    func moveKeyboardSelection(by step: Int, followingPins: Bool = true) {
        guard isKeyboardSession, let application = currentApplication, isEnabled(application),
              let next = Self.nextKeyboardRow(after: keyboardRow, in: application.windows, step: step,
                                              among: followingPins ? pinnedRing : nil) else { return }
        lastKeyboardLetter = nil
        showKeyboardRow(next)
    }

    /// The pinned windows of this Space that the shortcut goes round, in the list's order.
    /// One pinned window has nothing to go round with, so it takes two.
    var pinnedRing: [Int]? {
        guard let application = currentApplication else { return nil }
        let rows = application.windows.indices.filter {
            application.windows[$0].isInThisSpace && pins.containsWindow(application.windows[$0].pinKey, of: application.identifier)
        }
        return rows.count >= 2 ? rows : nil
    }

    /// To the first row starting with this letter, or on from the row a press of it reached.
    func jumpKeyboardSelection(to letter: Character) {
        guard isKeyboardSession, let application = currentApplication, isEnabled(application),
              let next = Self.keyboardRow(startingWith: letter,
                                          after: lastKeyboardLetter == letter ? keyboardRow : nil,
                                          in: application.windows) else { return }
        lastKeyboardLetter = letter
        showKeyboardRow(next)
    }

    private func showKeyboardRow(_ row: Int) {
        keyboardRow = row
        hasMovedKeyboardRow = true
        windowsTable.reloadData()
        windowsTable.scrollRowToVisible(row)
    }

    /// The next row starting with this letter that the keys can reach, going round. Without
    /// a row to go on from, the first in the list.
    static func keyboardRow(startingWith letter: Character, after row: Int?, in windows: [ListedWindow]) -> Int? {
        guard !windows.isEmpty else { return nil }
        let start = row ?? -1
        return (1...windows.count)
            .map { (start + $0) % windows.count }
            .first { windows[$0].isInThisSpace && startsWith(windows[$0].title, letter) }
    }

    private static func startsWith(_ title: String, _ letter: Character) -> Bool {
        guard let first = title.first else { return false }
        return String(first).compare(String(letter), options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
    }

    /// The keys were released. The rest is what a click on that row does.
    func commitKeyboardSelection() {
        guard isKeyboardSession else { return }
        isKeyboardSession = false
        guard let application = currentApplication, isEnabled(application),
              let row = keyboardRow, application.windows.indices.contains(row) else {
            close()
            return
        }
        apply(rows: [row], of: application)
    }

    func cancelKeyboardSession() {
        isKeyboardSession = false
        close()
    }

    /// The next row that the keys can reach, going round. It starts after the window in
    /// front, because that is the one being switched away from.
    /// With `among`, only those rows are reached.
    static func nextKeyboardRow(after row: Int?, in windows: [ListedWindow], step: Int = 1, among: [Int]? = nil) -> Int? {
        guard !windows.isEmpty else { return nil }
        let count = windows.count
        let start = row ?? windows.lastIndex(where: \.isFrontmost) ?? (step > 0 ? -1 : 0)
        return (1...count)
            .map { ((start + $0 * step) % count + count) % count }
            .first { windows[$0].isInThisSpace && among?.contains($0) != false }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let quitting, Date().timeIntervalSince(quitting.requested) < Self.quitWindow else {
            closeAfterLosingFocus()
            return
        }
        // Quitting the frontmost application brings another one forward, which takes the
        // focus. If it has not quit, it may be asking about unsaved work, and a panel at
        // this level would cover that, so the panel goes.
        Task { @MainActor [weak self] in
            for _ in 0..<Self.quitChecks where !quitting.application.isTerminated {
                try? await Task.sleep(nanoseconds: Self.quitCheckNanoseconds)
            }
            guard let self else { return }
            if quitting.application.isTerminated {
                self.panel.makeKey()
            } else {
                self.closeAfterLosingFocus()
            }
        }
    }

    /// A panel at this level would cover a question about unsaved work, and an application
    /// that stays in the background when it asks takes no focus to close the panel.
    private func watchForAQuestion(from application: ManagedApplication, questionsBefore: Int) {
        Task { @MainActor [weak self] in
            for _ in 0..<Self.questionChecks {
                try? await Task.sleep(nanoseconds: Self.quitCheckNanoseconds)
                guard let self, self.panel.isVisible, !application.isTerminated else { return }
                if await Self.questionCount(of: application) > questionsBefore {
                    self.closeAfterLosingFocus()
                    return
                }
            }
        }
    }

    /// The application answers this, and one that is quitting can take its time.
    private nonisolated static func questionCount(of application: ManagedApplication) async -> Int {
        application.questionCount
    }

    private func closeAfterLosingFocus() {
        lastClosed = Date()
        close()
    }

    /// Pressing the menu bar icon takes key focus from the panel and closes it just
    /// before the click arrives. Without this check that click would reopen it.
    var wasJustClosed: Bool {
        lastClosed.map { Date().timeIntervalSince($0) < Self.reopenGuard } ?? false
    }

    // MARK: Selection

    func chooseApplication(_ index: Int?) {
        selectedApplication = index
        selection.clear()
        keyboardRow = nil
        showWhetherEnabled()
        windowsTable.reloadData()
        let problem = index.flatMap { applications[$0].problem }
        problemLabel.stringValue = problem ?? ""
        problemLabel.isHidden = problem == nil
        if panel.isVisible { placePanel() }
    }

    func clickWindow(row: Int, shift: Bool) {
        guard let application = currentApplication, isEnabled(application), application.windows.indices.contains(row) else { return }
        if shift {
            selection.toggle(row)
            windowsTable.reloadData()
        } else {
            selection.clear()
            apply(rows: [row], of: application)
        }
    }

    /// A Shift+click selection takes effect when Shift is released.
    func shiftReleased() {
        guard let application = currentApplication, isEnabled(application), !selection.rows.isEmpty else { return }
        let rows = selection.rows
        selection.clear()
        apply(rows: rows, of: application)
    }

    /// The panel stays open, so several applications can be quit in turn. The row goes
    /// away when the application has really quit, which it may decline to do.
    func quitChosenApplication() {
        frontmostNameWhenOpened = nil
        guard let application = currentApplication else { return }
        quitting = (application.application, Date())
        let questionsBefore = application.application.questionCount
        guard !application.application.terminate() else {
            watchForAQuestion(from: application.application, questionsBefore: questionsBefore)
            return
        }
        quitting = nil
        problemLabel.stringValue = "\(application.name) could not be asked to quit."
        problemLabel.isHidden = false
        placePanel()
    }

    private var currentApplication: ListedApplication? {
        selectedApplication.map { applications[$0] }
    }

    private func apply(rows: [Int], of application: ListedApplication) {
        close()
        onApply(application, rows.map { application.windows[$0] })
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === applicationsTable ? applications.count : (currentApplication?.windows.count ?? 0)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === applicationsTable {
            return applicationCell(row: row)
        }
        guard let window = currentApplication?.windows[row] else { return nil }
        let suffix = window.isMinimized ? "  (Minimized)" : ""
        let label = NSTextField(labelWithString: window.title + suffix)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = Self.windowTextColor(window)
        label.toolTip = window.toolTip
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The badge's place is kept when empty, so titles do not shift as rows are chosen.
        let cell = Self.row([windowPinButton(row: row, window: window), OrderBadge(number: selection.order(of: row)), label])
        guard extraHeight(ofRow: row) > 0 else { return cell }
        // The window's own part of the row is as tall as any other row, under the rest.
        let holder = NSView()
        cell.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(cell)
        NSLayoutConstraint.activate([
            cell.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            cell.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            cell.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            cell.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        ])
        if let heading = sectionHeading(forRow: row) {
            // Starts where the badges do, so the window names sit one step in from it.
            let title = NSTextField(labelWithString: heading)
            title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            title.textColor = Self.quietTextColor
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            title.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(title)
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 6),
                title.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -8),
                title.bottomAnchor.constraint(equalTo: cell.topAnchor)
            ])
        }
        return holder
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if tableView === applicationsTable { return ApplicationRowView() }
        if row == keyboardRow { return KeyboardRowView(hasLine: hasLineAbove(row: row)) }
        return hasLineAbove(row: row) ? SeparatedRowView() : nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        tableView === windowsTable ? Self.rowHeight + extraHeight(ofRow: row) : Self.rowHeight
    }

    /// The accent color itself is too bright for text on light glass: 1.45:1 over the grey in a
    /// real screenshot. This comes to 3.73:1 there, measured, and the user was happy with it.
    /// Dark glass has no such trouble.
    private static let frontWindowTextColor = NSColor(name: nil) { appearance in
        guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua,
              let darker = NSColor.controlAccentColor.usingColorSpace(.sRGB)?.blended(withFraction: 0.5, of: .black) else {
            return .controlAccentColor
        }
        return darker
    }

    /// The windows on show stand out, so they can be found at a glance: every one of them,
    /// since several can be side by side. Another Space's windows are not on show here.
    static func windowTextColor(_ window: ListedWindow) -> NSColor {
        if !window.isMinimized && window.isInThisSpace { return frontWindowTextColor }
        return window.isMinimized ? quietTextColor : .labelColor
    }

    private func pinButton(pinned: Bool, row: Int, action: Selector) -> NSButton {
        let symbol = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: pinned ? "Unpin" : "Pin")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        let pin = NSButton(image: symbol ?? NSImage(), target: self, action: action)
        pin.isBordered = false
        pin.tag = row
        pin.toolTip = pinned ? "Unpin" : "Pin to the top"
        pin.contentTintColor = pinned ? .controlAccentColor : .tertiaryLabelColor
        pin.translatesAutoresizingMaskIntoConstraints = false
        pin.widthAnchor.constraint(equalToConstant: 18).isActive = true
        return pin
    }

    private func windowPinButton(row: Int, window: ListedWindow) -> NSButton {
        let pinned = currentApplication.map { pins.containsWindow(window.pinKey, of: $0.identifier) } ?? false
        let pin = pinButton(pinned: pinned, row: row, action: #selector(windowPinClicked(_:)))
        pin.isEnabled = currentApplication.map(isEnabled) ?? true
        return pin
    }

    private func applicationCell(row: Int) -> NSView {
        let application = applications[row]
        let cell = ApplicationCell(application: application, quietTextColor: Self.quietTextColor,
                                   switchedOffTextColor: Self.switchedOffTextColor)
        cell.power.target = self
        cell.power.action = #selector(enabledSwitchClicked(_:))
        cell.show(enabled: isEnabled(application), animated: false)
        return cell
    }

    func isEnabled(_ application: ListedApplication) -> Bool {
        disabled.isEnabled(application.identifier)
    }

    /// The applications Switch is on for come first, in the order given, and those it is off
    /// for after them. The switch takes the place of the application's pin (the user's choice).
    /// Each application has its pinned windows first.
    private func arranged(_ applications: [ListedApplication]) -> [ListedApplication] {
        let ordered = pins.ordered(applications)
        return ordered.filter(isEnabled) + ordered.filter { !isEnabled($0) }
    }

    /// Turns Switch on or off for an application. The row changes where it is, so the knob is
    /// seen to slide, and slides to its new place among the others at the same time. What was
    /// chosen among its windows is let go, since nothing can be done with it now.
    func setEnabled(_ enabled: Bool, row: Int) {
        guard applications.indices.contains(row) else { return }
        let identifier = applications[row].identifier
        let chosen = currentApplication?.identifier
        disabled.setEnabled(enabled, for: identifier)
        if let cell = applicationsTable.view(atColumn: 0, row: row, makeIfNecessary: false) as? ApplicationCell {
            cell.show(enabled: enabled, animated: true)
        }
        let rearranged = arranged(listedApplications)
        let destination = rearranged.firstIndex { $0.identifier == identifier }
        applications = rearranged
        if let destination, destination != row {
            // The table keeps the chosen row chosen as it moves, which is not a new choice.
            isMovingRows = true
            applicationsTable.moveRow(at: row, to: destination)
            isMovingRows = false
        }
        selectedApplication = chosen.flatMap { chosen in applications.firstIndex { $0.identifier == chosen } }
        if let selectedApplication, applicationsTable.selectedRow != selectedApplication {
            chooseRowForTheUser(selectedApplication)
        }
        if applications[destination ?? row].identifier == chosen {
            selection.clear()
            keyboardRow = nil
            showWhetherEnabled()
            windowsTable.reloadData()
            if panel.isVisible { placePanel() }
        }
        onEnabledChanged?()
    }

    @objc private func enabledSwitchClicked(_ sender: PowerSwitch) {
        guard let row = applications.firstIndex(where: { $0.identifier == sender.identifier?.rawValue }) else { return }
        setEnabled(sender.isOn, row: row)
    }

    /// The windows of an application Switch is off for are shown faded under a note that says so.
    private func showWhetherEnabled() {
        let application = currentApplication
        let enabled = application.map(isEnabled) ?? true
        disabledNotice.isHidden = enabled
        if let application, !enabled {
            disabledNotice.titleText = "Switch is off for \(application.name)"
        }
        windowsScroll.alphaValue = enabled ? 1 : Self.switchedOffListAlpha
    }

    private static let switchedOffListAlpha: CGFloat = 0.45

    /// Fainter than the quiet text, and still readable, so the name can be found to turn it on.
    fileprivate static var switchedOffTextColor: NSColor {
        if #available(macOS 26, *) { return labelColor(alpha: 0.4) }
        return .tertiaryLabelColor
    }

    /// The icon in greys.
    fileprivate static func switchedOffIcon(_ icon: NSImage) -> NSImage {
        // Twice the size it is shown at, for a Retina display.
        var rect = NSRect(x: 0, y: 0, width: 36, height: 36)
        guard let cgImage = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let filter = CIFilter(name: "CIColorControls") else { return icon }
        filter.setValue(CIImage(cgImage: cgImage), forKey: kCIInputImageKey)
        filter.setValue(0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage,
              let grey = CIContext().createCGImage(output, from: output.extent) else { return icon }
        return NSImage(cgImage: grey, size: icon.size)
    }

    /// Pins or unpins a window, and moves the rows. What has been chosen with Shift stays chosen.
    func toggleWindowPin(row: Int) {
        guard let index = selectedApplication, isEnabled(applications[index]), applications[index].windows.indices.contains(row),
              let listed = listedApplications.first(where: { $0.identifier == applications[index].identifier }) else { return }
        pins.toggleWindow(applications[index].windows[row].pinKey, of: listed.identifier)
        let before = applications[index].windows
        applications[index].windows = pins.windowOrder(of: listed).map { listed.windows[$0] }
        var moved = WindowSelection()
        for old in selection.rows {
            let key = before[old].pinKey
            // Rows with the same key move together, so the same one among them is kept.
            let nth = before[..<old].filter { $0.pinKey == key }.count
            let matches = applications[index].windows.indices.filter { applications[index].windows[$0].pinKey == key }
            if matches.indices.contains(nth) { moved.toggle(matches[nth]) }
        }
        selection = moved
        windowsTable.reloadData()
    }

    @objc private func windowPinClicked(_ sender: NSButton) {
        toggleWindowPin(row: sender.tag)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === applicationsTable, !isMovingRows else { return }
        if !isChoosingForTheUser {
            frontmostNameWhenOpened = nil
            hasMovedKeyboardRow = false
            lastKeyboardLetter = nil
        }
        let row = applicationsTable.selectedRow
        chooseApplication(row >= 0 ? row : nil)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        tableView === applicationsTable
    }

    @objc private func windowsTableClicked() {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        let clicked = windowsTable.clickedRow
        guard clicked >= 0, let event = NSApp.currentEvent else { return }
        let point = windowsTable.convert(event.locationInWindow, from: nil)
        guard let row = windowRow(clickedRow: clicked, offsetFromRowTop: point.y - windowsTable.rect(ofRow: clicked).minY) else { return }
        clickWindow(row: row, shift: shift)
    }

    @objc private func requestPermission() {
        onRequestPermission()
    }

    /// The same settings as the right-click menu. The panel stays open behind the menu, and
    /// moves at once if its place was what changed.
    @objc private func showSettings() {
        guard let menu = settingsMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: settingsButton.bounds.maxY + 4), in: settingsButton)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.placePanel()
            }
        }
    }

    // MARK: Views

    private static func row(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 8)
        return stack
    }

    private static func scrollView(for table: NSTableView, identifier: String) -> NSScrollView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.drawsBackground = false
        table.backgroundColor = .clear
        return scroll
    }

    private func buildContent() {
        for table in [applicationsTable, windowsTable] {
            table.dataSource = self
            table.delegate = self
        }
        windowsTable.target = self
        windowsTable.action = #selector(windowsTableClicked)
        windowsTable.ringRows = { [weak self] in self?.pinnedRing }

        windowsColumn.orientation = .vertical
        windowsColumn.alignment = .leading
        windowsColumn.spacing = 8
        windowsColumn.addArrangedSubview(disabledNotice)
        windowsColumn.addArrangedSubview(windowsScroll)
        for view in [disabledNotice, windowsScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: windowsColumn.widthAnchor).isActive = true
        }
        disabledNotice.setContentHuggingPriority(.required, for: .vertical)
        disabledNotice.isHidden = true
        windowsScroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        lists.addArrangedSubview(applicationsScroll)
        lists.addArrangedSubview(windowsColumn)
        lists.orientation = .horizontal
        lists.distribution = .fill
        applicationsScroll.widthAnchor.constraint(equalToConstant: Self.applicationsWidth).isActive = true

        problemLabel.textColor = .systemRed
        // A wrapping label reports its height for this width, which the panel's height relies on.
        problemLabel.preferredMaxLayoutWidth = Self.contentWidth
        problemLabel.isHidden = true

        let permissionLabel = NSTextField(wrappingLabelWithString: Self.permissionMessage)
        permissionLabel.preferredMaxLayoutWidth = Self.contentWidth - 140
        let permissionButton = NSButton(title: "Open Settings", target: self, action: #selector(requestPermission))
        permissionBar.orientation = .horizontal
        permissionBar.addArrangedSubview(permissionLabel)
        permissionBar.addArrangedSubview(permissionButton)

        let hintLabel = NSTextField(labelWithString: Self.hint)
        hintLabel.textColor = Self.quietTextColor
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: SwitchSettings.title)
        settingsButton.imagePosition = .imageOnly
        settingsButton.isBordered = false
        settingsButton.toolTip = SwitchSettings.title
        settingsButton.target = self
        settingsButton.action = #selector(showSettings)
        settingsButton.isHidden = settingsMenu == nil
        let footer = NSStackView(views: [hintLabel, spacer, settingsButton])
        footer.orientation = .horizontal

        for view in [permissionBar, problemLabel, lists, footer] {
            content.addArrangedSubview(view)
        }
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        let topInset: CGFloat
        if #available(macOS 26, *) { topInset = 12 } else { topInset = 28 }
        content.edgeInsets = NSEdgeInsets(top: topInset, left: 12, bottom: 12, right: 12)
        for view in [lists, footer, permissionBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24).isActive = true
        }
        lists.setContentHuggingPriority(.defaultLow, for: .vertical)
        if #available(macOS 26, *) {
            // The regular style. The clear one was hard to read, even with a veil (the user's view).
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 20
            glass.contentView = content
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.contentView = glass
        } else {
            panel.contentView = content
        }
    }

    static let disabledDetail = "The shortcut is left to macOS while it is in front, and its windows are not switched, arranged or minimized."
    /// The windows' side, less the card's margins and the symbol.
    private static let disabledNoticeTextWidth: CGFloat = contentWidth - applicationsWidth - 8 - 42

    private static var noticeFillColor: NSColor {
        if #available(macOS 26, *) { return labelColor(alpha: 0.07) }
        return .quaternaryLabelColor
    }

    /// Text that gives way to the rest. Over glass the usual grey is too faint to read when
    /// a page of text is behind it, so it is darker there.
    fileprivate static var quietTextColor: NSColor {
        if #available(macOS 26, *) { return labelColor(alpha: 0.72) }
        return .secondaryLabelColor
    }

    /// The text color at this strength, worked out again for each appearance. A label keeps its
    /// color, and the text color with an alpha is fixed in the appearance it was made in
    /// (measured: in a dark panel the hint stayed dark), so a label made before the appearance
    /// changed kept the old one.
    private static func labelColor(alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var color = NSColor.labelColor
            appearance.performAsCurrentDrawingAppearance {
                color = NSColor.labelColor.withAlphaComponent(alpha).usingColorSpace(.sRGB) ?? .labelColor
            }
            return color
        }
    }

    fileprivate static var lineColor: NSColor {
        if #available(macOS 26, *) { return NSColor.labelColor.withAlphaComponent(0.25) }
        return .separatorColor
    }

    var windowsRowCountForTesting: Int { numberOfRows(in: windowsTable) }
    var frameForTesting: NSRect { panel.frame }
    var settingsButtonForTesting: NSButton { settingsButton }

    /// What a click on an application's row does.
    func selectApplicationRowForTesting(_ row: Int) {
        applicationsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    var separatedRowForTesting: Int? { separatedRow }

    func orderBadgeForTesting(row: Int) -> OrderBadge? {
        let view = tableView(windowsTable, viewFor: nil, row: row)
        return (view?.subviews.compactMap { $0 as? OrderBadge }.first)
            ?? view?.subviews.flatMap(\.subviews).compactMap { $0 as? OrderBadge }.first
    }

    #if DEBUG
    func setKeyboardRowForTesting(_ row: Int) {
        keyboardRow = row
    }

    /// Draws the panel into an image, for looking at the design without a screen capture.
    func renderForTesting(appearance: NSAppearance, height: CGFloat) -> NSBitmapImageRep? {
        panel.appearance = appearance
        panel.setFrame(NSRect(x: 0, y: 0, width: panel.frame.width, height: height), display: false)
        guard let view = panel.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        applicationsTable.reloadData()
        windowsTable.reloadData()
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    #endif
    var panelFrameForTesting: NSRect { panel.frame }
    var isKeyForTesting: Bool { panel.isKeyWindow }

    /// A window row's center in screen coordinates.
    func windowRowCenterForTesting(row: Int) -> NSPoint {
        panel.layoutIfNeeded()
        let rect = windowsTable.rect(ofRow: row)
        let inWindow = windowsTable.convert(NSPoint(x: rect.midX, y: rect.maxY - Self.rowHeight / 2), to: nil)
        return panel.convertPoint(toScreen: inWindow)
    }

    func applicationsListHeightForTesting() -> CGFloat {
        panel.layoutIfNeeded()
        return applicationsScroll.contentView.bounds.height
    }

    /// Heights of the window list's rows and of the area that shows them.
    func windowsListHeightsForTesting() -> (rows: CGFloat, visible: CGFloat) {
        panel.layoutIfNeeded()
        windowsTable.layoutSubtreeIfNeeded()
        return (windowRowsHeight, windowsScroll.contentView.bounds.height)
    }
}
