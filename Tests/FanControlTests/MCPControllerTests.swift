import XCTest
@testable import FanControl

final class MCPControllerTests: XCTestCase {
    private final class FakeHardware: MCPHardware {
        let lease = UUID().uuidString
        var owner: String?
        var commands: [String] = []
        var authorizationCount = 0
        var failRelease = false
        var failManual = false
        var readings = [FanReading(id: 0, rpm: 1000, minimum: 1000, maximum: 4900, manual: true)]
        func authorize() throws { authorizationCount += 1 }
        func snapshot() throws -> Snapshot { Snapshot(fans: readings, temperatures: []) }
        func fans() throws -> [FanReading] { readings }
        func request(_ command: String) throws {
            commands.append(command)
            let parts = command.split(separator: " ").map(String.init)
            switch parts[0] {
            case "manual":
                if failManual { throw FanError("Write failed") }
                guard owner == nil || owner == parts[1] else { throw FanError("Another owner") }
                owner = parts[1]
            case "heartbeat":
                guard owner == parts[1] else { throw FanError("Stale lease") }
            case "release":
                if failRelease { throw FanError("Reset failed") }
                if owner == parts[1] { owner = nil }
            case "system": owner = nil
            default: XCTFail("Unexpected command: \(command)")
            }
        }
    }

    func testReadOnlyConnectionAndCloseNeverAuthorizeOrReset() throws {
        let hardware = FakeHardware()
        let controller = MCPFanController(hardware: hardware, startTimer: false)
        let result = try controller.call("get_status", arguments: [:])
        XCTAssertEqual(result["owns_manual_control"] as? Bool, false)
        controller.checkHeartbeat()
        controller.close()
        XCTAssertEqual(hardware.authorizationCount, 0)
        XCTAssertTrue(hardware.commands.isEmpty)
    }

    func testIdleConnectionHeartbeatsAndCloseReleasesOnlyItsLease() throws {
        let hardware = FakeHardware()
        let controller = MCPFanController(hardware: hardware, startTimer: false)
        _ = try controller.call("set_fan_percent", arguments: ["percent": 84])
        controller.checkHeartbeat()
        XCTAssertEqual(hardware.commands, ["manual \(hardware.lease) 84.0", "heartbeat \(hardware.lease) 84.0"])
        controller.close()
        XCTAssertEqual(hardware.commands.last, "release \(hardware.lease)")
        XCTAssertNil(hardware.owner)
        let count = hardware.commands.count
        controller.checkHeartbeat()
        controller.close()
        XCTAssertEqual(hardware.commands.count, count)
    }

    func testStaleConnectionCannotReleaseNewOwnersLease() throws {
        let hardware = FakeHardware()
        let controller = MCPFanController(hardware: hardware, startTimer: false)
        _ = try controller.call("set_fan_percent", arguments: ["percent": 84])
        let newerOwner = UUID().uuidString
        hardware.owner = newerOwner // Another client explicitly reset and took over.
        controller.checkHeartbeat()
        XCTAssertEqual(hardware.owner, newerOwner)
        XCTAssertEqual(hardware.commands.last, "release \(hardware.lease)")
        XCTAssertFalse(hardware.commands.contains("system"))
        let status = try controller.call("get_status", arguments: [:])
        XCTAssertEqual(status["owns_manual_control"] as? Bool, false)
        XCTAssertEqual(status["control_error"] as? String, "Stale lease")
        controller.close()
        XCTAssertEqual(hardware.owner, newerOwner)
    }

    func testFailedAcquisitionDoesNotResetOtherOwner() throws {
        let hardware = FakeHardware()
        hardware.owner = UUID().uuidString
        let controller = MCPFanController(hardware: hardware, startTimer: false)
        XCTAssertThrowsError(try controller.call("set_fan_percent", arguments: ["percent": 84]))
        controller.close()
        XCTAssertEqual(hardware.commands.count, 1)
        XCTAssertTrue(hardware.commands[0].hasPrefix("manual "))
    }

    func testFailedReleaseStopsHeartbeatsForWatchdogRecovery() throws {
        let hardware = FakeHardware()
        let controller = MCPFanController(hardware: hardware, startTimer: false)
        _ = try controller.call("set_fan_percent", arguments: ["percent": 84])
        hardware.failRelease = true
        controller.close()
        let count = hardware.commands.count
        controller.checkHeartbeat()
        XCTAssertEqual(hardware.commands.count, count)
        let status = try controller.call("get_status", arguments: [:])
        XCTAssertEqual(status["owns_manual_control"] as? Bool, false)
        XCTAssertTrue((status["control_error"] as? String ?? "").contains("watchdog"))
    }

    func testFailedRPMResponseReleasesAndReportsError() throws {
        let hardware = FakeHardware()
        var now = 0.0
        let controller = MCPFanController(hardware: hardware, startTimer: false, uptime: { now })
        _ = try controller.call("set_fan_percent", arguments: ["percent": 100])
        now = 11
        controller.checkHeartbeat()
        XCTAssertNil(hardware.owner)
        let status = try controller.call("get_status", arguments: [:])
        XCTAssertEqual(status["owns_manual_control"] as? Bool, false)
        XCTAssertTrue((status["control_error"] as? String ?? "").contains("did not respond"))
        controller.close()
    }

    func testExplicitRestoreCanRevokeOtherOwner() throws {
        let hardware = FakeHardware()
        hardware.owner = UUID().uuidString
        let controller = MCPFanController(hardware: hardware, startTimer: false)
        let result = try controller.call("restore_system", arguments: [:])
        XCTAssertEqual(result["system_control_restored"] as? Bool, true)
        XCTAssertNil(hardware.owner)
        XCTAssertEqual(hardware.commands, ["system"])
        controller.close()
    }
}
