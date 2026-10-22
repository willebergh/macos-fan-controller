import Foundation
import CoreFoundation
import Darwin

// Newline-delimited JSON-RPC over stdio. stdout is reserved for protocol messages.
final class MCPServer {
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private let callTool: (String, [String: Any]) throws -> [String: Any]
    private var initialized = false

    init(callTool: @escaping (String, [String: Any]) throws -> [String: Any]) {
        self.callTool = callTool
    }

    static let tools: [[String: Any]] = [
        ["name": "get_status", "description": "Read current fan RPM, hardware limits, mode, and available temperatures. Does not require administrator authorization.",
         "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]],
        ["name": "set_fan_percent", "description": "Request a manual percentage of maximum RPM for all fans, clamped to hardware minimums. May show a macOS administrator authorization dialog. No thermal cutoff. Keep this MCP process alive to maintain the override; closing stdin restores system control. Fails if another instance owns manual control. Accepted targets are not proof of measured RPM; use get_status to inspect settling/response errors.",
         "inputSchema": ["type": "object", "properties": ["percent": ["type": "number", "minimum": 0, "maximum": 100]], "required": ["percent"], "additionalProperties": false]],
        ["name": "restore_system", "description": "Restore and verify Apple's automatic fan control. This explicitly ends any current manual override, including one owned by the menu-bar app. May require administrator authorization.",
         "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]]
    ]

    func handle(_ data: Data) -> Data? {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { return encode(self.error(id: NSNull(), code: -32700, message: "Parse error")) }
        guard let request = object as? [String: Any], request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else {
            return encode(error(id: NSNull(), code: -32600, message: "Invalid request"))
        }
        let id = request["id"]
        if let id, !(id is NSNull), !(id is String), !Self.isNumber(id) {
            return encode(error(id: NSNull(), code: -32600, message: "Invalid request ID"))
        }
        // Notifications never receive replies or invoke mutating tools.
        guard let id else { return nil }
        if let params = request["params"], !(params is [String: Any]) {
            return encode(error(id: id, code: -32602, message: "Expected object params"))
        }
        let params = request["params"] as? [String: Any] ?? [:]
        var result: [String: Any]
        switch method {
        case "initialize":
            guard let version = params["protocolVersion"] as? String,
                  params["capabilities"] is [String: Any], params["clientInfo"] is [String: Any] else {
                return encode(error(id: id, code: -32602, message: "Missing initialization parameters"))
            }
            initialized = true
            result = ["protocolVersion": Self.protocolVersions.contains(version) ? version : Self.protocolVersions[0],
                      "capabilities": ["tools": ["listChanged": false]],
                      "serverInfo": ["name": "fancontrol", "version": "1.0.0"],
                      "instructions": "Fan writes require local administrator approval. Manual control lasts only while this server is connected. Temperatures do not limit manual speed."]
        case "ping": result = [:]
        case "tools/list", "tools/call":
            guard initialized else { return encode(error(id: id, code: -32000, message: "Initialize first")) }
            if method == "tools/list" {
                result = ["tools": Self.tools]
            } else {
                guard let name = params["name"] as? String,
                      Self.tools.contains(where: { $0["name"] as? String == name }) else {
                    return encode(error(id: id, code: -32602, message: "Unknown tool"))
                }
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                guard params["arguments"] == nil || params["arguments"] is [String: Any],
                      Self.validArguments(name: name, arguments: arguments) else {
                    return encode(error(id: id, code: -32602, message: "Invalid tool arguments"))
                }
                do {
                    let value = try callTool(name, arguments)
                    let text = String(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
                    result = ["content": [["type": "text", "text": text]], "structuredContent": value, "isError": false]
                } catch {
                    result = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
                }
            }
        default: return encode(error(id: id, code: -32601, message: "Method not found"))
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func isNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.isFinite
    }

    private static func validArguments(name: String, arguments: [String: Any]) -> Bool {
        if name != "set_fan_percent" { return arguments.isEmpty }
        guard arguments.count == 1, let raw = arguments["percent"], isNumber(raw),
              let number = raw as? NSNumber else { return false }
        return (0...100).contains(number.doubleValue)
    }

    private func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func encode(_ value: [String: Any]) -> Data {
        // All response values are JSON-compatible, including tool results checked above.
        try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    static func run() throws {
        // Broken stdout should throw, not terminate before lease cleanup runs.
        signal(SIGPIPE, SIG_IGN)
        let controller = MCPFanController()
        defer { controller.close() }
        let server = MCPServer { name, arguments in try controller.call(name, arguments: arguments) }
        var buffer = Data()
        // Bound frame memory. MCP stdio messages are one JSON object per line.
        while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard line.count <= 1_048_576 else { throw FanError("MCP message exceeds 1 MiB.") }
                if let response = server.handle(line) {
                    try FileHandle.standardOutput.write(contentsOf: response + Data([10]))
                }
            }
            guard buffer.count <= 1_048_576 else { throw FanError("MCP message exceeds 1 MiB.") }
        }
    }
}

protocol MCPHardware {
    var lease: String { get }
    func authorize() throws
    func snapshot() throws -> Snapshot
    func fans() throws -> [FanReading]
    func request(_ command: String) throws
}

extension HardwareController: MCPHardware {
    func snapshot() throws -> Snapshot { try connection().snapshot() }
    func fans() throws -> [FanReading] { try connection().fans() }
    func request(_ command: String) throws { _ = try PrivilegedHelper.request(command) }

    private func connection() throws -> SMC {
        if smc == nil { smc = try SMC() }
        return smc!
    }
}

// All hardware access, including heartbeats, is serialized independently of stdin.
// A quiet client must not starve the helper's 10-second watchdog.
final class MCPFanController {
    private let queue = DispatchQueue(label: "personal-fan.mcp-hardware")
    private let hardware: any MCPHardware
    private let uptime: () -> TimeInterval
    private var timer: DispatchSourceTimer?
    private var ownsManual = false
    private var percent = 100.0
    private var monitor: FanResponseMonitor?
    private var lastError: String?
    private var activity: NSObjectProtocol?

    init(hardware: any MCPHardware = HardwareController(), startTimer: Bool = true,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.hardware = hardware
        self.uptime = uptime
        guard startTimer else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.heartbeat() }
        self.timer = timer
        timer.resume()
    }

    func call(_ name: String, arguments: [String: Any]) throws -> [String: Any] {
        try queue.sync {
            switch name {
            case "get_status": return try status()
            case "set_fan_percent":
                let requested = (arguments["percent"] as! NSNumber).doubleValue
                let initial = try hardware.fans()
                try hardware.authorize()
                do { try hardware.request("manual \(hardware.lease) \(requested)") }
                catch {
                    // If this process previously owned manual control, stop renewing
                    // it after a failed write. Never reset another instance's lease.
                    if ownsManual { restoreOwned() }
                    throw error
                }
                ownsManual = true
                percent = requested
                lastError = nil
                monitor = FanResponseMonitor(startedAt: uptime(), initial: initial, percent: requested)
                if activity == nil {
                    activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Maintain MCP manual fan-control heartbeat")
                }
                return ["accepted": true, "percent": percent, "verification": "waiting_for_measured_rpm", "lifetime": "until connection closes or control fails"]
            case "restore_system":
                // Explicit user-requested restoration can revoke another owner's lease.
                try hardware.authorize()
                try hardware.request("system")
                clearOwnership()
                lastError = nil
                return ["system_control_restored": true]
            default: throw FanError("Unknown tool.")
            }
        }
    }

    private func status() throws -> [String: Any] {
        let snapshot = try hardware.snapshot()
        var result: [String: Any] = [
            "fans": snapshot.fans.map { fan -> [String: Any] in
                ["id": fan.id, "rpm": fan.rpm, "minimum_rpm": fan.minimum,
                 "maximum_rpm": fan.maximum, "manual": fan.manual.map { $0 as Any } ?? NSNull()]
            },
            "temperatures": snapshot.temperatures.map { ["sensor": $0.id, "name": $0.name, "celsius": $0.celsius] as [String: Any] },
            "owns_manual_control": ownsManual,
            "verification": monitor == nil ? "not_pending" : "waiting_for_measured_rpm"
        ]
        if ownsManual { result["requested_percent"] = percent }
        if let lastError { result["control_error"] = lastError }
        return result
    }

    private func heartbeat() {
        guard ownsManual else { return }
        do {
            try hardware.request("heartbeat \(hardware.lease) \(percent)")
            if let monitor {
                switch monitor.evaluate(try hardware.fans(), now: uptime()) {
                case .waiting: break
                case .reached: self.monitor = nil
                case .failed(let reason): throw FanError(reason)
                }
            }
        } catch {
            lastError = error.localizedDescription
            restoreOwned()
        }
    }

    private func restoreOwned() {
        guard ownsManual else { return }
        // Check lease ownership before resetting: if someone explicitly restored
        // system control and took over, our stale process must not reset them.
        do {
            try hardware.request("release \(hardware.lease)")
            clearOwnership()
        } catch {
            lastError = "\(lastError.map { $0 + " " } ?? "")Could not release manual control: \(error.localizedDescription) The helper watchdog will attempt recovery."
            // Stop heartbeats; the helper remains responsible for failed resets.
            clearOwnership()
            fputs("\(lastError!)\n", stderr)
        }
    }

    private func clearOwnership() {
        ownsManual = false
        monitor = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }

    // Also permits deterministic watchdog tests without sleeping or SMC writes.
    func checkHeartbeat() { queue.sync { heartbeat() } }

    func close() {
        queue.sync {
            timer?.cancel()
            timer = nil
            restoreOwned()
        }
    }
}
