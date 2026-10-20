import Foundation

// Explicit, short hardware test: maximum cooling only, always followed by reset.
// Invoked by the developer/user via --test-control, never automatically at launch.
enum ControlDiagnostic {
    static func run() throws {
        guard getuid() != 0 else { throw FanError("Run the test as your login user; approve the macOS authorization dialog.") }
        let hardware = HardwareController()
        let smc = try SMC()
        let before = try smc.fans()
        print("Before: " + before.map { "fan \($0.id + 1) \(Int($0.rpm)) RPM" }.joined(separator: ", "))
        fflush(stdout)
        try hardware.authorize()
        var resetConfirmed = false
        defer {
            if !resetConfirmed {
                do { _ = try PrivilegedHelper.request("system"); print("System control restored.") }
                catch { fputs("RESET FAILED: \(error.localizedDescription)\n", stderr) }
            }
        }
        _ = try PrivilegedHelper.request("manual \(hardware.lease) 100")
        var reachedMaximum = false
        for second in 1...15 {
            Thread.sleep(forTimeInterval: 1)
            _ = try PrivilegedHelper.request("heartbeat \(hardware.lease) 100")
            let fans = try smc.fans()
            print("\(second)s: " + fans.map { "fan \($0.id + 1) \(Int($0.rpm)) / \(Int($0.maximum)) RPM; manual=\($0.manual == true)" }.joined(separator: ", "))
            fflush(stdout)
            if fans.allSatisfy({ $0.manual == true && $0.rpm >= $0.maximum * 0.9 }) { reachedMaximum = true; break }
        }
        _ = try PrivilegedHelper.request("system")
        resetConfirmed = true
        let restored = try smc.fans()
        guard restored.allSatisfy({ $0.manual == false }) else { throw FanError("System control reset was not confirmed by the app's own SMC connection.") }
        print("System control restored and independently verified.")
        guard reachedMaximum else { throw FanError("The fan did not reach 90% of maximum within 15 seconds. Manual control is NOT verified.") }
        print("PASS: Actual fan RPM responded to maximum control.")
    }
}
