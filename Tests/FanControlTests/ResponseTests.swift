import XCTest
@testable import FanControl

final class ResponseTests: XCTestCase {
    private func fan(_ rpm: Double, manual: Bool = true) -> FanReading {
        FanReading(id: 0, rpm: rpm, minimum: 1000, maximum: 4900, manual: manual)
    }
    func testIgnoredMaximumRequestIsDetected() {
        let check = FanResponseMonitor(startedAt: 0, initial: [fan(1022)], percent: 100)
        XCTAssertEqual(check.evaluate([fan(1022)], now: 2), .waiting)
        guard case .failed(let message) = check.evaluate([fan(1022)], now: 11) else { return XCTFail("An ignored request must fail") }
        XCTAssertTrue(message.contains("4900"))
        XCTAssertTrue(message.contains("1022"))
    }
    func testSpinningUpGetsTimeToSettle() {
        let check = FanResponseMonitor(startedAt: 0, initial: [fan(1022)], percent: 100)
        XCTAssertEqual(check.evaluate([fan(3500)], now: 11), .waiting)
        XCTAssertEqual(check.evaluate([fan(4800)], now: 20), .reached)
        guard case .failed = check.evaluate([fan(3500)], now: 31) else { return XCTFail("Must eventually reach requested speed") }
    }
    func testLosingManualOwnershipIsDetected() {
        let check = FanResponseMonitor(startedAt: 0, initial: [fan(1022)], percent: 100)
        guard case .failed = check.evaluate([fan(1022, manual: false)], now: 3) else { return XCTFail("Must detect mode reverting") }
    }
}
