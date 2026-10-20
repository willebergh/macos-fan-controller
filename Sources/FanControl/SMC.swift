import Foundation
import SMCBridge

struct FanError: LocalizedError {
    let message: String
    let code: UInt32?
    var errorDescription: String? { message }
    init(_ message: String, code: UInt32? = nil) { self.message = message; self.code = code }
}

struct SMCValue {
    let type: String
    let bytes: [UInt8]

    var number: Double? {
        switch type {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        case "fpe2":
            guard bytes.count == 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "sp78":
            guard bytes.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "ui8 ": return bytes.first.map(Double.init)
        case "ui16", "ui32":
            guard bytes.count == (type == "ui16" ? 2 : 4) else { return nil }
            return Double(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        default: return nil
        }
    }

    func encoding(_ value: Double) throws -> [UInt8] {
        guard value.isFinite, value >= 0 else { throw FanError("Invalid SMC value.") }
        switch type {
        case "flt ":
            let bits = Float(value).bitPattern
            return (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        case "fpe2":
            guard value <= 16383 else { throw FanError("RPM out of range.") }
            let raw = UInt16((value * 4).rounded())
            return [UInt8(raw >> 8), UInt8(truncatingIfNeeded: raw)]
        case "ui8 ":
            guard value <= 255 else { throw FanError("Mode out of range.") }
            return [UInt8(value)]
        default: throw FanError("Unsupported writable SMC type: \(type)")
        }
    }
}

struct FanReading: Identifiable {
    let id: Int
    let rpm: Double
    let minimum: Double
    let maximum: Double
    let manual: Bool?
    var controllable: Bool { minimum.isFinite && maximum.isFinite && minimum > 0 && maximum > minimum && maximum <= 30000 }
    func target(percent: Double) -> Double {
        // Percentage of maximum RPM, clamped to the hardware minimum. Never stop the fan.
        min(maximum, max(minimum, maximum * percent / 100))
    }
}

struct TemperatureReading: Identifiable {
    let id: String
    let name: String
    let celsius: Double
}

struct Snapshot {
    var fans: [FanReading] = []
    var temperatures: [TemperatureReading] = []
}

final class SMC {
    private var connection: UInt32 = 0
    private var injectedRead: ((String) throws -> SMCValue)?
    private var injectedWrite: ((String, [UInt8]) throws -> Void)?
    private var unlockedTestMode = false
    private var temperatureKeys: [String]?
    private var safetyKeys: [String]?
    private var ownedModeKeys: [Int: String] = [:]
    private static let coreKeys = ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0T", "Tg0G", "Tg0H", "Tg05", "Tg0D", "Tg0L", "Tg0T", "Ts0P", "Ts0S"]

    init() throws {
        let result = smc_open(&connection)
        guard result == 0 else { throw FanError(String(format: "Cannot open AppleSMC (0x%08X).", result)) }
    }
    // In-memory transport for deterministic control/reset tests; never opens hardware.
    init(read: @escaping (String) throws -> SMCValue, write: @escaping (String, [UInt8]) throws -> Void) {
        injectedRead = read
        injectedWrite = write
    }
    deinit { smc_close(connection) }

    func read(_ key: String) throws -> SMCValue {
        guard key.utf8.count == 4 else { throw FanError("Invalid SMC key.") }
        if let injectedRead { return try injectedRead(key) }
        var type = [CChar](repeating: 0, count: 5)
        var bytes = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        let result = smc_read(connection, key, &type, &bytes, &size)
        guard result == 0 else { throw FanError(String(format: "Cannot read %@ (0x%08X).", key, result), code: result) }
        return SMCValue(type: String(cString: type), bytes: Array(bytes.prefix(Int(size))))
    }

    func number(_ key: String) throws -> Double {
        guard let number = try read(key).number else { throw FanError("Unsupported sensor format: \(key)") }
        return number
    }

    private func write(_ key: String, value: Double) throws {
        let original = try read(key)
        let bytes = try original.encoding(value)
        guard bytes.count == original.bytes.count else { throw FanError("Unexpected size for \(key).") }
        if let injectedWrite { return try injectedWrite(key, bytes) }
        let result = smc_write(connection, key, bytes, UInt32(bytes.count))
        guard result == 0 else { throw FanError(String(format: "Cannot write %@ (0x%08X). Control may not be supported on this Mac.", key, result)) }
    }

    func fans() throws -> [FanReading] {
        let rawCount = try number("FNum")
        guard rawCount >= 1, rawCount <= 8 else { throw FanError("No supported fans found.") }
        return try (0..<Int(rawCount)).map { index in
            let mode = (try? modeKey(index)).flatMap { try? number($0) }
            return FanReading(id: index, rpm: try number("F\(index)Ac"),
                              minimum: try number("F\(index)Mn"), maximum: try number("F\(index)Mx"),
                              manual: mode.flatMap { $0 == 1 ? true : (($0 == 0 || $0 == 3) ? false : nil) })
        }
    }

    private func modeKey(_ index: Int) throws -> String {
        if (try? read("F\(index)md")) != nil { return "F\(index)md" }
        _ = try read("F\(index)Md")
        return "F\(index)Md"
    }

    private func discoverTemperatures() -> [String] {
        guard let count = try? number("#KEY"), count > 0, count <= 30000 else { return [] }
        var keys: [String] = []
        for index in 0..<UInt32(count) {
            var key = [CChar](repeating: 0, count: 5)
            if smc_key_at(connection, index, &key) == 0 {
                let name = String(cString: key)
                if name.hasPrefix("T"), let value = try? number(name), value > 0, value < 130 { keys.append(name) }
            }
        }
        return keys.sorted()
    }

    func temperatures() -> [TemperatureReading] {
        if temperatureKeys == nil { temperatureKeys = discoverTemperatures() }
        let readings = (temperatureKeys ?? []).compactMap { key -> TemperatureReading? in
            guard let value = try? number(key), value > 0, value < 130 else { return nil }
            return TemperatureReading(id: key, name: key, celsius: value)
        }
        // Apple Silicon per-core CPU/GPU sensors. Report hottest available sensor in each group,
        // rather than pretending a random sensor is the chip's overall temperature.
        let groups: [(String, (String) -> Bool)] = [
            ("CPU (hottest core)", { ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0T"].contains($0) }),
            ("GPU (hottest sensor)", { ["Tg0G", "Tg0H", "Tg05", "Tg0D", "Tg0L", "Tg0T"].contains($0) }),
            ("SoC", { $0 == "Ts0P" || $0 == "Ts0S" })
        ]
        var result: [TemperatureReading] = []
        for (name, match) in groups {
            if let hottest = readings.filter({ match($0.id) }).max(by: { $0.celsius < $1.celsius }) {
                result.append(TemperatureReading(id: hottest.id, name: name, celsius: hottest.celsius))
            }
        }
        if result.isEmpty {
            // Unknown sensor maps stay explicitly identified by their hardware key.
            result = Array(readings.sorted { $0.celsius > $1.celsius }.prefix(3))
        }
        return result
    }

    // Safety telemetry is independent of display summaries. Once a sensor was
    // available, a failed/invalid reading fails closed instead of disappearing.
    func safetyTemperatures() throws -> [Double] {
        if safetyKeys == nil {
            var discovered: [String] = []
            for key in Self.coreKeys {
                do { _ = try read(key); discovered.append(key) }
                catch let error as FanError where error.code == 0xE0000084 {
                    continue // Firmware explicitly says this key does not exist.
                }
                // Permission, transport and other failures are not unsupported keys.
            }
            guard discovered.contains(where: { $0.hasPrefix("Tp") || $0.hasPrefix("Te") }),
                  discovered.contains(where: { $0.hasPrefix("Tg") }) else {
                throw FanError("Validated CPU and GPU temperature coverage is required for manual control.")
            }
            safetyKeys = discovered
        }
        guard let keys = safetyKeys, !keys.isEmpty else { throw FanError("No validated temperature sensors are available.") }
        return try keys.map { key in
            let value = try number(key)
            guard value > 0, value < 150 else { throw FanError("Invalid temperature from \(key).") }
            return value
        }
    }

    func snapshot() throws -> Snapshot { try Snapshot(fans: fans(), temperatures: temperatures()) }

    func setManual(percent: Double) throws {
        guard percent.isFinite, (0...100).contains(percent) else { throw FanError("Percentage must be 0–100.") }
        do {
            let readings = try fans()
            guard readings.allSatisfy(\.controllable) else { throw FanError("Invalid hardware RPM limits.") }
            // Cache modes before writes; preflight failures during an existing session
            // must also run rollback, using the previously cached modes.
            for fan in readings { ownedModeKeys[fan.id] = try modeKey(fan.id) }
            for fan in readings {
                let target = fan.target(percent: percent).rounded()
                let mode = ownedModeKeys[fan.id]!
                let targetKey = "F\(fan.id)Tg"
                // Some firmware ignores target writes while the system owns the fan.
                // Stage the desired target if supported; otherwise require the existing
                // target to be a safe nonzero seed before changing ownership.
                try? write(targetKey, value: target)
                try enableManualMode(mode) {
                    let seed = try self.number(targetKey)
                    guard seed >= fan.minimum, seed <= fan.maximum else {
                        throw FanError("Cannot establish a safe starting target for fan \(fan.id + 1). No manual override was enabled.")
                    }
                }
                try write(targetKey, value: target)
                guard try waitForManualMode(mode) else {
                    let observedMode = try number(mode)
                    throw FanError("Fan \(fan.id + 1) returned to mode \(Int(observedMode)) after manual activation.")
                }
                // Target readback can lag or be firmware-quantized. Do not undo
                // an accepted command just because Tg is not instantly identical.
                // AppModel independently verifies measured RPM response and resets
                // an ignored request after 10s (30s for a fan still settling).
            }
        } catch {
            try? reset()
            throw error
        }
    }

    private func waitForManualMode(_ mode: String) throws -> Bool {
        for attempt in 0..<10 {
            if try number(mode) == 1 { return true }
            if injectedWrite == nil, attempt < 9 { Thread.sleep(forTimeInterval: 0.05) }
        }
        return false
    }

    private func enableManualMode(_ mode: String, validateSeed: () throws -> Void) throws {
        try validateSeed()
        do {
            try write(mode, value: 1)
            // A successful write can still be immediately overridden by the thermal
            // manager. Treat that as an unlock requirement, not a completed handoff.
            guard try waitForManualMode(mode) else { throw FanError("Manual mode did not stay enabled.") }
            return
        }
        catch {
            // Older Apple Silicon firmware coordinates control through Ftst.
            // Never assume it exists based on chip generation (it is absent on this M4).
            let directError = error
            let unlock: SMCValue
            do { unlock = try read("Ftst") }
            catch let error as FanError where error.code == 0xE0000084 { throw directError }
            guard unlock.type == "ui8 ", unlock.bytes.count == 1, unlock.number == 0 || unlock.number == 1 else {
                throw FanError("Unsupported fan-control unlock format.")
            }
            unlockedTestMode = true // rollback must release even a partially accepted write
            try write("Ftst", value: 1)
            // Yield time for thermalmonitord, without blocking the UI thread.
            if injectedWrite == nil { Thread.sleep(forTimeInterval: 3) }
            var lastError: Error = directError
            for _ in 0..<20 {
                // Unlocking can change firmware targets. Revalidate immediately
                // before every ownership attempt, not before the unlock delay.
                try validateSeed()
                do {
                    try write(mode, value: 1)
                    if try number(mode) == 1 { return }
                    lastError = FanError("Manual mode did not stay enabled after unlocking.")
                }
                catch { lastError = error }
                if injectedWrite == nil { Thread.sleep(forTimeInterval: 0.1) }
            }
            throw lastError
        }
    }

    func reset() throws {
        var modes = ownedModeKeys
        var errors: [String] = []
        if modes.isEmpty {
            let count = try number("FNum")
            guard count >= 1, count <= 8 else { throw FanError("No supported fans found.") }
            for id in 0..<Int(count) {
                do { modes[id] = try modeKey(id) }
                catch { errors.append(error.localizedDescription) }
            }
        }
        for (_, mode) in modes.sorted(by: { $0.key < $1.key }) {
            do {
                try write(mode, value: 0)
                var confirmed = false
                for attempt in 0..<10 {
                    let value = try number(mode)
                    if value == 0 || value == 3 { confirmed = true; break }
                    if injectedWrite == nil, attempt < 9 { Thread.sleep(forTimeInterval: 0.05) }
                }
                guard confirmed else { throw FanError("System mode was not confirmed.") }
            } catch { errors.append(error.localizedDescription) }
        }
        if unlockedTestMode {
            do {
                try write("Ftst", value: 0)
                guard try number("Ftst") == 0 else { throw FanError("Fan-control unlock did not reset.") }
                unlockedTestMode = false
            } catch { errors.append(error.localizedDescription) }
        }
        if !errors.isEmpty { throw FanError(errors.joined(separator: "\n")) }
    }
}
