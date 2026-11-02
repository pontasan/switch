#if DEBUG
import XCTest
@testable import SwitchApp

final class AccessibilityProbeTests: XCTestCase {
    func testProbeRunsOnlyWhenRequestedExplicitly() {
        XCTAssertNil(AccessibilityProbe.outputPath(arguments: ["/app/SwitchApp"]))
        XCTAssertEqual(AccessibilityProbe.outputPath(arguments: ["/app/SwitchApp", "--ax-probe", "/tmp/out.json"]), "/tmp/out.json")
    }
}
#endif
