import XCTest
@testable import SwitchApp

final class SingleInstanceTests: XCTestCase {
    private let earlier = Date(timeIntervalSince1970: 1000)
    private let later = Date(timeIntervalSince1970: 2000)

    private func instance(_ pid: pid_t, _ date: Date) -> SingleInstance.Instance {
        SingleInstance.Instance(processIdentifier: pid, started: date)
    }

    func testAloneStays() {
        XCTAssertFalse(SingleInstance.shouldLeave(own: instance(1, later), others: []))
    }

    func testTheLaterOneLeavesAndTheEarlierOneStays() {
        XCTAssertTrue(SingleInstance.shouldLeave(own: instance(1, later), others: [instance(2, earlier)]))
        XCTAssertFalse(SingleInstance.shouldLeave(own: instance(2, earlier), others: [instance(1, later)]))
    }

    func testOfTwoStartingTogetherExactlyOneStays() {
        let a = instance(5, earlier), b = instance(6, earlier)
        XCTAssertFalse(SingleInstance.shouldLeave(own: a, others: [b]))
        XCTAssertTrue(SingleInstance.shouldLeave(own: b, others: [a]))
    }
}
