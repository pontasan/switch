import AppKit
import XCTest
@testable import SwitchApp

private final class FakeLoginItem: LoginItem {
    var isEnabled = false
    var needsApproval = false
    var registered = 0
    var failure: Error?
    func register() throws {
        if let failure { throw failure }
        registered += 1
        isEnabled = true
    }
    func unregister() throws { isEnabled = false }
}

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "com.tranworks.switch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testTheFirstLaunchTurnsItOn() {
        let item = FakeLoginItem()
        LaunchAtLogin(item: item, defaults: defaults()).setUpOnFirstLaunch()
        XCTAssertTrue(item.isEnabled)
    }

    func testTurningItOffLasts() {
        let item = FakeLoginItem()
        let store = defaults()
        let launchAtLogin = LaunchAtLogin(item: item, defaults: store)
        launchAtLogin.setUpOnFirstLaunch()
        launchAtLogin.toggle()
        XCTAssertFalse(item.isEnabled)
        LaunchAtLogin(item: item, defaults: store).setUpOnFirstLaunch()
        XCTAssertFalse(item.isEnabled, "the next launch must not turn it back on")
    }

    func testTheMenuShowsTheStateAndChangesIt() {
        let item = FakeLoginItem()
        let launchAtLogin = LaunchAtLogin(item: item, defaults: defaults())
        XCTAssertEqual(launchAtLogin.makeMenuItem().state, .off)
        launchAtLogin.toggle()
        XCTAssertEqual(launchAtLogin.makeMenuItem().state, .on)
        let titles = MenuBarController.makeMenu(launchAtLogin: launchAtLogin).items.map(\.title)
        XCTAssertEqual(titles.filter { !$0.isEmpty }, [MenuBarController.aboutTitle, LaunchAtLogin.title, MenuBarController.quitTitle])
    }

    func testAFailedChangeIsReported() {
        struct Refused: Error {}
        let item = FakeLoginItem()
        item.failure = Refused()
        var reported: [String] = []
        LaunchAtLogin(item: item, defaults: defaults(), onFailure: { reported.append($0) }).toggle()
        XCTAssertEqual(reported.count, 1)
    }
}

@MainActor
final class MenuBarControllerTests: XCTestCase {
    func testMenuOffersAWayToQuit() throws {
        let menu = MenuBarController.makeMenu()
        XCTAssertEqual(menu.items.last?.title, MenuBarController.quitTitle)
        XCTAssertEqual(menu.items.last?.action, #selector(NSApplication.terminate(_:)))
    }

    func testMenuOffersAboutFirst() throws {
        let about = try XCTUnwrap(MenuBarController.makeMenu().items.first)
        XCTAssertEqual(about.title, MenuBarController.aboutTitle)
        XCTAssertTrue(about.target === AboutPanel.shared)
        XCTAssertEqual(about.action, #selector(AboutPanel.show))
    }

    func testAboutSaysTheVersionFromTheBundleOnce() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        let options = AboutPanel.options(info: plist)
        XCTAssertEqual(options[.applicationVersion] as? String, plist["CFBundleShortVersionString"] as? String)
        XCTAssertEqual(options[.applicationVersion] as? String, "1.1.0")
        XCTAssertEqual(options[.version] as? String, "")
    }

    func testStatusItemShowsATemplateIconAndReportsClicks() throws {
        var anchors: [NSRect] = []
        let controller = MenuBarController(onClick: { anchors.append($0) })
        defer { controller.invalidate() }
        XCTAssertEqual(controller.imageForTesting?.isTemplate, true)
        controller.clickForTesting()
        XCTAssertEqual(anchors.count, 1)
    }

    func testStatusItemButtonActuallyDrawsTheIcon() throws {
        let controller = MenuBarController(onClick: { _ in })
        defer { controller.invalidate() }
        let button = try XCTUnwrap(controller.buttonForTesting)
        button.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(button.bounds.width, 0)
        XCTAssertGreaterThan(button.bounds.height, 0)

        let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: bitmap)
        var inkPixels = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                inkPixels += 1
            }
        }
        XCTAssertGreaterThan(inkPixels, 10, "the menu bar button rendered blank")
    }

    func testBundleIsAMenuBarOnlyAppWithItsOwnIdentity() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.tranworks.switch")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "SwitchApp")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
    }
}
