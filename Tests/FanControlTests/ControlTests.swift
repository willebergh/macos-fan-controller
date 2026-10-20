import XCTest
@testable import FanControl

final class ControlTests: XCTestCase {
    private let absent = FanError("missing", code: 0xE0000084)

    private func float(_ value: Double) -> SMCValue {
        SMCValue(type: "flt ", bytes: try! SMCValue(type: "flt ", bytes: [0, 0, 0, 0]).encoding(value))
    }

    private func makeStore(target: Double = 1022, includeUnlock: Bool = false) -> [String: SMCValue] {
        var values: [String: SMCValue] = [
            "FNum": SMCValue(type: "ui8 ", bytes: [1]),
            "F0Ac": float(1022), "F0Mn": float(1000), "F0Mx": float(4900),
            "F0Tg": float(target), "F0Md": SMCValue(type: "ui8 ", bytes: [0])
        ]
        if includeUnlock { values["Ftst"] = SMCValue(type: "ui8 ", bytes: [0]) }
        return values
    }

    func testSafeExistingTargetAllowsManualWhenSystemIgnoresTargetWrites() throws {
        var values = makeStore()
        let smc = SMC(read: { key in guard let value = values[key] else { throw self.absent }; return value }, write: { key, bytes in
            if key == "F0Tg", values["F0Md"]?.number == 0 { return }
            values[key] = SMCValue(type: key == "F0Md" ? "ui8 " : "flt ", bytes: bytes)
        })

        try smc.setManual(percent: 50)
        XCTAssertEqual(values["F0Md"]?.number, 1)
        XCTAssertEqual(values["F0Tg"]?.number ?? 0, 2450, accuracy: 0.1)
    }

    func testUnsafeSeedRefusesToEnableManualMode() {
        var values = makeStore(target: 0)
        let smc = SMC(read: { key in guard let value = values[key] else { throw self.absent }; return value }, write: { key, bytes in
            if key == "F0Tg", values["F0Md"]?.number == 0 { return }
            values[key] = SMCValue(type: key == "F0Md" ? "ui8 " : "flt ", bytes: bytes)
        })
        XCTAssertThrowsError(try smc.setManual(percent: 50))
        XCTAssertEqual(values["F0Md"]?.number, 0)
    }

    func testTargetWriteFailureAfterEnablingRollsBackToSystemMode() {
        var values = makeStore()
        let smc = SMC(read: { key in guard let value = values[key] else { throw self.absent }; return value }, write: { key, bytes in
            if key == "F0Tg", values["F0Md"]?.number == 1 { throw FanError("target write failed") }
            values[key] = SMCValue(type: key == "F0Md" ? "ui8 " : "flt ", bytes: bytes)
        })
        XCTAssertThrowsError(try smc.setManual(percent: 50))
        XCTAssertEqual(values["F0Md"]?.number, 0)
    }

    func testResetAfterAcquisitionDoesNotNeedRPMTelemetry() throws {
        var values = makeStore()
        let smc = SMC(read: { key in guard let value = values[key] else { throw self.absent }; return value }, write: { key, bytes in
            values[key] = SMCValue(type: key == "F0Md" ? "ui8 " : "flt ", bytes: bytes)
        })
        try smc.setManual(percent: 50)
        values.removeValue(forKey: "F0Ac")
        try smc.reset()
        XCTAssertEqual(values["F0Md"]?.number, 0)
    }

    func testLaggingTargetReadbackDoesNotImmediatelyUndoAcceptedControl() throws {
        var values = makeStore()
        let smc = SMC(read: { key in guard let value = values[key] else { throw self.absent }; return value }, write: { key, bytes in
            // Hardware accepts the target command, but reports its previous Tg
            // until firmware completes the handoff. Actual RPM is checked later.
            if key == "F0Tg" { return }
            values[key] = SMCValue(type: "ui8 ", bytes: bytes)
        })
        try smc.setManual(percent: 100)
        XCTAssertEqual(values["F0Md"]?.number, 1)
        XCTAssertEqual(values["F0Tg"]?.number, 1022)
    }

    func testQuantizedTargetDoesNotTriggerRollback() throws {
        var values = makeStore()
        let smc = SMC(read: { key in guard let value = values[key] else { throw self.absent }; return value }, write: { key, bytes in
            if key == "F0Tg" {
                values[key] = self.float(1280) // 26% requests 1274, firmware rounds.
            } else { values[key] = SMCValue(type: "ui8 ", bytes: bytes) }
        })
        try smc.setManual(percent: 26)
        XCTAssertEqual(values["F0Md"]?.number, 1)
    }

    func testPreflightFailureDuringManualSessionResetsImmediately() throws {
        var values = makeStore()
        let smc = SMC(read: { key in guard let value = values[key] else { throw self.absent }; return value }, write: { key, bytes in
            values[key] = SMCValue(type: key == "F0Md" ? "ui8 " : "flt ", bytes: bytes)
        })
        try smc.setManual(percent: 50)
        values.removeValue(forKey: "F0Ac")
        XCTAssertThrowsError(try smc.setManual(percent: 100))
        XCTAssertEqual(values["F0Md"]?.number, 0)
    }

    func testUnlockInvalidatingSeedDoesNotAcquireOwnership() {
        var values = makeStore(includeUnlock: true)
        var acquired = false
        let smc = SMC(read: { key in guard let value = values[key] else { throw self.absent }; return value }, write: { key, bytes in
            if key == "F0Md", bytes == [1] {
                if values["Ftst"]?.number != 1 { throw FanError("locked") }
                acquired = true
            }
            values[key] = SMCValue(type: key == "F0Md" || key == "Ftst" ? "ui8 " : "flt ", bytes: bytes)
            if key == "Ftst", bytes == [1] { values["F0Tg"] = self.float(0) }
        })
        XCTAssertThrowsError(try smc.setManual(percent: 100))
        XCTAssertFalse(acquired)
        XCTAssertEqual(values["Ftst"]?.number, 0)
    }

    func testFtstUnlockIsReleasedByReset() throws {
        var values = makeStore(includeUnlock: true)
        let smc = SMC(read: { key in guard let value = values[key] else { throw self.absent }; return value }, write: { key, bytes in
            if key == "F0Md", values["Ftst"]?.number != 1 { throw FanError("mode write locked") }
            values[key] = SMCValue(type: key == "F0Md" || key == "Ftst" ? "ui8 " : "flt ", bytes: bytes)
        })
        try smc.setManual(percent: 50)
        XCTAssertEqual(values["Ftst"]?.number, 1)
        try smc.reset()
        XCTAssertEqual(values["F0Md"]?.number, 0)
        XCTAssertEqual(values["Ftst"]?.number, 0)
    }
}
