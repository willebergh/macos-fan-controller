import XCTest
@testable import FanControl

final class MCPServerTests: XCTestCase {
    private func send(_ server: MCPServer, _ value: Any) throws -> [String: Any]? {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        guard let response = server.handle(data) else { return nil }
        return try JSONSerialization.jsonObject(with: response) as? [String: Any]
    }

    private func initialize(_ server: MCPServer, version: String = "2025-11-25") throws -> [String: Any] {
        try XCTUnwrap(send(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": version, "capabilities": [:], "clientInfo": ["name": "tests", "version": "1"]
        ]]))
    }

    func testInitializeNegotiationAndToolDiscoveryDoNotAccessHardware() throws {
        let server = MCPServer { _, _ in XCTFail("Discovery must be read-only"); return [:] }
        let response = try initialize(server)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-11-25")
        let legacy = try initialize(server, version: "2024-11-05")
        XCTAssertEqual((legacy["result"] as? [String: Any])?["protocolVersion"] as? String, "2024-11-05")
        let future = try initialize(server, version: "unknown-future-version")
        XCTAssertEqual((future["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        let list = try send(server, ["jsonrpc": "2.0", "id": "tools", "method": "tools/list"])
        let tools = (list?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.compactMap { $0["name"] as? String }, ["get_status", "set_fan_percent", "restore_system"])
        XCTAssertEqual(list?["id"] as? String, "tools")
    }

    func testNotificationsNeverReplyOrMutate() throws {
        var calls = 0
        let server = MCPServer { _, _ in calls += 1; return [:] }
        _ = try initialize(server)
        XCTAssertNil(try send(server, ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertNil(try send(server, ["jsonrpc": "2.0", "method": "tools/call", "params": ["name": "restore_system"]]))
        XCTAssertEqual(calls, 0)
    }

    func testManualArgumentsValidateBeforeHardwareCall() throws {
        var values: [Double] = []
        let server = MCPServer { name, arguments in
            XCTAssertEqual(name, "set_fan_percent")
            values.append((arguments["percent"] as! NSNumber).doubleValue)
            return ["accepted": true]
        }
        _ = try initialize(server)
        let invalid: [[String: Any]] = [[:], ["percent": -1], ["percent": 101], ["percent": true], ["percent": "84"], ["percent": NSNull()], ["percent": 84, "extra": 1]]
        for arguments in invalid {
            let response = try send(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "set_fan_percent", "arguments": arguments]])
            XCTAssertEqual((response?["error"] as? [String: Any])?["code"] as? Int, -32602)
        }
        XCTAssertTrue(values.isEmpty)
        for percent in [0.0, 84.5, 100.0] {
            let response = try send(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "set_fan_percent", "arguments": ["percent": percent]]])
            let result = response?["result"] as? [String: Any]
            XCTAssertEqual(result?["isError"] as? Bool, false)
            XCTAssertEqual((result?["structuredContent"] as? [String: Any])?["accepted"] as? Bool, true)
        }
        XCTAssertEqual(values, [0, 84.5, 100])
    }

    func testReadAndRestoreRejectUnexpectedArguments() throws {
        let server = MCPServer { _, _ in XCTFail("Must reject before invoking backend"); return [:] }
        _ = try initialize(server)
        for name in ["get_status", "restore_system"] {
            let response = try send(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": name, "arguments": ["unexpected": true]]])
            XCTAssertEqual((response?["error"] as? [String: Any])?["code"] as? Int, -32602)
        }
    }

    func testHardwareErrorsAreToolErrorsNotProtocolErrors() throws {
        let server = MCPServer { _, _ in throw FanError("Authorization cancelled.") }
        _ = try initialize(server)
        let response = try send(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "restore_system"]])
        XCTAssertNil(response?["error"])
        let result = response?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        XCTAssertEqual((result?["content"] as? [[String: Any]])?.first?["text"] as? String, "Authorization cancelled.")
    }

    func testInvalidProtocolRequests() throws {
        let server = MCPServer { _, _ in XCTFail("Invalid request reached hardware"); return [:] }
        let malformed = try XCTUnwrap(server.handle(Data("{broken".utf8)))
        let parsed = try JSONSerialization.jsonObject(with: malformed) as! [String: Any]
        XCTAssertEqual((parsed["error"] as? [String: Any])?["code"] as? Int, -32700)
        for object: Any in [[], 7, ["jsonrpc": "1.0", "id": 1, "method": "ping"], ["jsonrpc": "2.0", "id": true, "method": "ping"]] {
            let response = try send(server, object)
            XCTAssertEqual((response?["error"] as? [String: Any])?["code"] as? Int, -32600)
        }
        let beforeInit = try send(server, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        XCTAssertEqual((beforeInit?["error"] as? [String: Any])?["code"] as? Int, -32000)
        let unknown = try send(server, ["jsonrpc": "2.0", "id": 1, "method": "unknown"])
        XCTAssertEqual((unknown?["error"] as? [String: Any])?["code"] as? Int, -32601)
        let ping = try send(server, ["jsonrpc": "2.0", "id": 1, "method": "ping"])
        XCTAssertNotNil(ping?["result"])
    }
}
