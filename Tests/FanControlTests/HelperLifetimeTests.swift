import XCTest
import SMCBridge
import Darwin
@testable import FanControl

final class HelperLifetimeTests: XCTestCase {
    func testKernelProcessIdentityIsStableAndRejectsMissingProcesses() {
        let identity = fan_process_identity(getpid())
        XCTAssertNotEqual(identity, 0)
        XCTAssertEqual(fan_process_identity(getpid()), identity)
        XCTAssertEqual(fan_process_identity(0), 0)
        XCTAssertEqual(fan_process_identity(Int32.max), 0)
    }
    func testAuthorizedAppKeepsHelperAcrossLongIdleAndThermalReset() {
        XCTAssertFalse(HelperLifetime.shouldExit(manual: false, hasLiveClients: true, idleSeconds: 3600))
    }
    func testHelperExitsAfterClientQuitsAndGracePeriodExpires() {
        XCTAssertTrue(HelperLifetime.shouldExit(manual: false, hasLiveClients: false, idleSeconds: 61))
        XCTAssertFalse(HelperLifetime.shouldExit(manual: false, hasLiveClients: false, idleSeconds: 10))
    }
    func testFailedResetRetainsRecoveryResponsibility() {
        XCTAssertFalse(HelperLifetime.shouldExit(manual: true, hasLiveClients: false, idleSeconds: 3600))
    }
}
