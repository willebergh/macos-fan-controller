import XCTest
@testable import FanControl

final class SMCTests: XCTestCase {
    func testFloatRoundTrip() throws {
        let value = SMCValue(type: "flt ", bytes: [0, 0, 0, 0])
        let encoded = try value.encoding(2750)
        XCTAssertEqual(SMCValue(type: "flt ", bytes: encoded).number, 2750)
        XCTAssertEqual(encoded, [0, 224, 43, 69])
    }
    func testFixedPoint() throws {
        let value = SMCValue(type: "fpe2", bytes: [0x2e, 0xe0])
        XCTAssertEqual(value.number, 3000)
        XCTAssertEqual(try value.encoding(3000), value.bytes)
    }
    func testSignedTemperature() {
        XCTAssertEqual(SMCValue(type: "sp78", bytes: [0xff, 0x80]).number, -0.5)
        XCTAssertEqual(SMCValue(type: "sp78", bytes: [0x32, 0x80]).number, 50.5)
    }
    func testUnsignedAndMalformed() {
        XCTAssertEqual(SMCValue(type: "ui32", bytes: [0, 0, 1, 0]).number, 256)
        XCTAssertNil(SMCValue(type: "flt ", bytes: [0]).number)
        XCTAssertNil(SMCValue(type: "sp78", bytes: []).number)
        XCTAssertNil(SMCValue(type: "flt ", bytes: [0, 0, 128, 127]).number)
        XCTAssertNil(SMCValue(type: "nope", bytes: [0]).number)
    }
    func testPercentClampsToHardwareRange() {
        let fan = FanReading(id: 0, rpm: 1000, minimum: 1000, maximum: 4900, manual: false)
        XCTAssertTrue(fan.controllable)
        XCTAssertEqual(fan.target(percent: 0), 1000)
        XCTAssertEqual(fan.target(percent: 50), 2450)
        XCTAssertEqual(fan.target(percent: 100), 4900)
        XCTAssertEqual(fan.target(percent: -1), 1000)
        XCTAssertEqual(fan.target(percent: 200), 4900)
    }
    func testRejectZeroOrInvalidHardwareFloor() {
        XCTAssertFalse(FanReading(id: 0, rpm: 0, minimum: 0, maximum: 4900, manual: false).controllable)
        XCTAssertFalse(FanReading(id: 0, rpm: 0, minimum: 1000, maximum: 1000, manual: false).controllable)
        XCTAssertFalse(FanReading(id: 0, rpm: 0, minimum: .nan, maximum: 4900, manual: false).controllable)
    }
    func testRejectInvalidEncoding() {
        let value = SMCValue(type: "fpe2", bytes: [0, 0])
        XCTAssertThrowsError(try value.encoding(-1))
        XCTAssertThrowsError(try value.encoding(.nan))
        XCTAssertThrowsError(try value.encoding(20000))
    }
    func testSystemPower() throws {
        let value = SMCValue(type: "flt ", bytes: [0, 0, 0, 0])
        let bytes = try value.encoding(49.5)
        let smc = SMC(read: { key in
            XCTAssertEqual(key, "PSTR")
            return SMCValue(type: "flt ", bytes: bytes)
        }, write: { _, _ in XCTFail("Power readings must be read-only") })
        XCTAssertEqual(smc.systemPower(), 49.5)
    }

    func testSystemPowerUnavailableOrInvalid() {
        let missing = SMC(read: { _ in throw FanError("Unavailable") }, write: { _, _ in })
        XCTAssertNil(missing.systemPower())
        for bytes: [UInt8] in [[0, 0, 128, 191], [0, 0, 128, 127], [0]] {
            let smc = SMC(read: { _ in SMCValue(type: "flt ", bytes: bytes) }, write: { _, _ in })
            XCTAssertNil(smc.systemPower())
        }
        let zero = SMC(read: { _ in SMCValue(type: "flt ", bytes: [0, 0, 0, 0]) }, write: { _, _ in })
        XCTAssertEqual(zero.systemPower(), 0)
    }

    func testShellQuoting() {
        XCTAssertEqual(shellQuote("a'b"), "'a'\\''b'")
        XCTAssertEqual(appleScriptQuote("a\"b\\c"), "\"a\\\"b\\\\c\"")
    }
}
