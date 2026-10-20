import Foundation
import Darwin
import SMCBridge

// No shell, file-writing or arbitrary SMC operations are exposed over this socket.
// Only this login user's requests are accepted; the client verifies a root peer.
enum PrivilegedHelper {
    static func request(_ command: String, uid: uid_t = getuid()) throws -> String {
        let fd = fan_connect(uid)
        guard fd >= 0 else { throw FanError("Fan control is not authorized. Move the slider to authorize it.") }
        defer { close(fd) }
        let data = Array((command + "\n").utf8)
        let sent = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard sent == data.count else { throw FanError("Could not contact the fan helper.") }
        var buffer = [UInt8](repeating: 0, count: 2048)
        let count = Darwin.read(fd, &buffer, buffer.count)
        guard count > 0 else { throw FanError("The fan helper did not respond.") }
        let reply = String(decoding: buffer.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard reply == "OK" else { throw FanError(reply.hasPrefix("ERROR ") ? String(reply.dropFirst(6)) : reply) }
        return reply
    }

    static func run(uid: uid_t) throws {
        guard geteuid() == 0, uid > 0 else { throw FanError("Helper requires administrator authorization and a non-root client.") }
        let smc = try SMC()
        let server = fan_server(uid)
        guard server >= 0 else { throw FanError("Cannot start fan helper; another instance or stale socket may exist.") }
        defer { close(server); fan_remove_socket(uid) }
        signal(SIGPIPE, SIG_IGN)
        var manual = false
        var lease: String?
        var lastContact = ProcessInfo.processInfo.systemUptime
        var lastManual = lastContact
        var shouldExit = false
        var lastSafetyCheck = 0.0
        var requestedPercent = 100.0
        var clients: [pid_t: UInt64] = [:]
        // poll() bounds idle time and ensures the watchdog runs without a connected app.
        while !shouldExit {
            var descriptor = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 500)
            let now = ProcessInfo.processInfo.systemUptime
            if manual {
                var unsafe = now - lastManual > 10
                if now - lastSafetyCheck > 2 {
                    let temperatures = try? smc.safetyTemperatures()
                    unsafe = unsafe || !FanSafetyPolicy.permits(percent: requestedPercent, temperatures: temperatures ?? [])
                    lastSafetyCheck = now
                }
                if unsafe {
                    lease = nil
                    do { try smc.reset(); manual = false }
                    catch { fputs("Fan reset failed: \(error.localizedDescription)\n", stderr) }
                }
            }
            // Authorization belongs to the lifetime of the connected app, not a
            // short idle timer. Kernel peer PIDs cannot be forged in a request.
            // This also survives App Nap while the user is in system mode.
            clients = clients.filter { pid, identity in fan_process_identity(pid) == identity }
            // If reset fails, stay alive and retry; never abandon manual control.
            if HelperLifetime.shouldExit(manual: manual, hasLiveClients: !clients.isEmpty,
                                         idleSeconds: now - lastContact) { break }
            guard ready > 0 else { continue }
            let client = fan_accept(server, uid)
            guard client >= 0 else { continue }
            let clientPID = fan_peer_pid(client)
            let identity = fan_process_identity(clientPID)
            if clientPID > 0, identity != 0 { clients[clientPID] = identity }
            var buffer = [UInt8](repeating: 0, count: 128)
            let count = Darwin.read(client, &buffer, buffer.count)
            var reply = "ERROR Invalid command"
            if count > 0, count < buffer.count {
                let command = String(decoding: buffer.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                lastContact = now
                do {
                    if command == "ping" || command == "session 2" { reply = "OK" }
                    else if command == "system" || command == "quit" {
                        lease = nil
                        try smc.reset(); manual = false; reply = "OK"
                        shouldExit = command == "quit"
                    } else {
                        let parts = command.split(separator: " ").map(String.init)
                        guard parts.count == 3, parts[0] == "manual" || parts[0] == "heartbeat",
                              UUID(uuidString: parts[1]) != nil, let percent = Double(parts[2]),
                              percent.isFinite, (0...100).contains(percent) else { throw FanError("Invalid command.") }
                        let token = parts[1]
                        if parts[0] == "heartbeat" {
                            guard manual, lease == token else { throw FanError("Manual control ended. Move the slider to start it again.") }
                        } else if let owner = lease, owner != token {
                            throw FanError("Another FanControl instance owns manual control.")
                        }
                        let temperatures: [Double]
                        do { temperatures = try smc.safetyTemperatures() }
                        catch {
                            lease = nil
                            try smc.reset(); manual = false
                            throw error
                        }
                        guard FanSafetyPolicy.permits(percent: percent, temperatures: temperatures) else {
                            lease = nil
                            try smc.reset(); manual = false
                            throw FanError("Manual request not applied: a core is at least 95 °C. Choose 100% for maximum cooling or use system default.")
                        }
                        lease = token
                        // Mark ownership before attempting any writes, so a partial write + reset
                        // failure still leaves the watchdog responsible for restoring system mode.
                        manual = true
                        do { try smc.setManual(percent: percent) }
                        catch {
                            // A partial write triggers rollback inside SMC. Revoke the
                            // intent even if rollback failed, while retaining watchdog duty.
                            lease = nil
                            let originalError = error
                            do { try smc.reset(); manual = false }
                            catch { throw FanError("\(originalError.localizedDescription) System reset also failed: \(error.localizedDescription)") }
                            throw originalError
                        }
                        requestedPercent = percent
                        lastManual = ProcessInfo.processInfo.systemUptime
                        reply = "OK"
                    }
                } catch { reply = "ERROR " + error.localizedDescription.replacingOccurrences(of: "\n", with: " ") }
            }
            let response = Array((reply + "\n").utf8)
            _ = response.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
            close(client)
        }
    }
}

enum HelperLifetime {
    static func shouldExit(manual: Bool, hasLiveClients: Bool, idleSeconds: TimeInterval) -> Bool {
        !manual && !hasLiveClients && idleSeconds > 60
    }
}

enum FanSafetyPolicy {
    static func permits(percent: Double, temperatures: [Double]) -> Bool {
        guard percent.isFinite, (0...100).contains(percent), !temperatures.isEmpty,
              temperatures.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 150 }) else { return false }
        // Maximum cooling must remain available precisely when the chip is hot.
        return percent == 100 || temperatures.allSatisfy { $0 < 95 }
    }
}

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func appleScriptQuote(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
