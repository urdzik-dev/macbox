import Foundation
import MacBoxCore
import MacBoxProtocol
import CryptoKit

/// Stdio MCP endpoint for the isolated guest desktop.
enum MCPServer {
    static func run(layout: StorageLayout) {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = message["method"] as? String else { continue }
            guard let id = message["id"] else { continue }
            let params = message["params"] as? [String: Any] ?? [:]
            var result: [String: Any] = [:]
            var error: [String: Any]?
            switch method {
            case "initialize":
                let supported = ["2024-11-05", "2025-03-26", "2025-06-18"]
                let requested = params["protocolVersion"] as? String ?? ""
                result = ["protocolVersion": supported.contains(requested) ? requested : "2025-03-26",
                          "capabilities": ["tools": [:]],
                          "serverInfo": ["name": "macbox", "version": "0.1.0"]]
            case "ping": result = [:]
            case "tools/list":
                let string: [String: Any] = ["type": "string"]
                let number: [String: Any] = ["type": "integer"]
                func tool(_ name: String, _ description: String, _ extra: [String: Any], _ required: [String]) -> [String: Any] {
                    var properties = extra; properties["vm"] = string
                    if ["click", "move", "drag", "scroll", "type", "key"].contains(name) {
                        properties["screenshot"] = ["type": "boolean", "description": "Return a screenshot after the action."]
                    }
                    return ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": ["vm"] + required]]
                }
                result = ["tools": [
                    tool("vm_status", "Read VM configuration", [:], []),
                    tool("status", "Check guest permissions", [:], []),
                    tool("screenshot", "Capture guest display; pass the previous sha256 to omit an identical image.", ["if_hash": string], []),
                    tool("click", "Click guest display", ["x": number, "y": number], ["x", "y"]),
                    tool("move", "Move guest pointer", ["x": number, "y": number], ["x", "y"]),
                    tool("drag", "Drag in guest", ["x": number, "y": number, "toX": number, "toY": number], ["x", "y", "toX", "toY"]),
                    tool("scroll", "Scroll in guest", ["x": number, "y": number, "dx": number, "dy": number], ["x", "y", "dy"]),
                    tool("type", "Type text in guest", ["text": string], ["text"]),
                    tool("key", "Press a guest key combination", ["key": string], ["key"])
                ]]
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                do {
                    guard let vm = (args["vm"] ?? args["name"]) as? String else { throw MCPError.invalid("vm is required") }
                    let config = try layout.loadConfig(named: vm)
                    let paths = try layout.vmPaths(named: vm)
                    if name == "vm_status" {
                        let payload: [String: Any] = ["name": config.name, "installed": config.installed, "locked": VMLock.isLocked(at: paths.lockFile), "cpuCount": config.cpuCount, "memoryGiB": config.memoryGiB]
                        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                        result = ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
                    } else {
                        guard VMLock.isLocked(at: paths.lockFile) else { throw MCPError.invalid("VM is not running") }
                        func integer(_ field: String) throws -> Int {
                            guard let value = args[field] as? Int else { throw MCPError.invalid("Missing integer: " + field) }; return value
                        }
                        func point(_ x: String = "x", _ y: String = "y") throws -> ControlProtocol.Point { try .init(x: integer(x), y: integer(y)) }
                        let action: ControlProtocol.Action
                        switch name {
                        case "status": action = .status
                        case "screenshot":
                            if let raw = args["if_hash"] as? String {
                                action = .screenshotIfChanged(raw.hasPrefix("sha256:") ? String(raw.dropFirst(7)) : raw)
                            } else { action = .screenshot }
                        case "click": action = try .click(point(), button: .left, count: 1)
                        case "move": action = try .move(point())
                        case "drag": action = try .drag(from: point(), to: point("toX", "toY"))
                        case "scroll": action = try .scroll(point(), dx: args["dx"] as? Int ?? 0, dy: integer("dy"))
                        case "type": guard let text = args["text"] as? String else { throw MCPError.invalid("text is required") }; action = .type(text)
                        case "key": guard let key = args["key"] as? String else { throw MCPError.invalid("key is required") }; action = .key(key)
                        default: throw MCPError.invalid("Unknown tool")
                        }
                        let mailbox = try Mailbox(path: paths.exchange.path)
                        let response = try mailbox.request(.init(action: action))
                        switch response.result {
                        case .ok:
                            if args["screenshot"] as? Bool == true {
                                // Action success must remain explicit even if capture fails; do not invite a retry.
                                usleep(250_000)
                                do {
                                    let capture = try mailbox.request(.init(action: .screenshot))
                                    guard case let .imagePNG(data, width, height) = capture.result else {
                                        throw MCPError.invalid("Screenshot was not returned")
                                    }
                                    result = ["content": [["type": "text", "text": "Action completed. Screen: \(width)x\(height)."], ["type": "image", "mimeType": "image/png", "data": data.base64EncodedString()]]]
                                } catch {
                                    result = ["isError": true, "content": [["type": "text", "text": "Action completed, but screenshot failed: \(error). Do not repeat the action without checking its result."]]]
                                }
                            } else {
                                result = ["content": [["type": "text", "text": "OK"]]]
                            }
                        case let .status(screen, accessibility): result = ["content": [["type": "text", "text": "screenRecording=\(screen) accessibility=\(accessibility)"]]]
                        case let .imagePNG(data, width, height):
                            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                            let description = "\(width)x\(height) sha256:\(hash)"
                            if let previous = args["if_hash"] as? String, previous == hash || previous == "sha256:" + hash {
                                result = ["content": [["type": "text", "text": "Unchanged. \(description)"]]]
                            } else {
                                result = ["content": [["type": "image", "mimeType": "image/png", "data": data.base64EncodedString()], ["type": "text", "text": description]]]
                            }
                        case let .unchanged(hash, width, height): result = ["content": [["type": "text", "text": "Unchanged. \(width)x\(height) sha256:\(hash)"]]]
                        case let .failure(code, message): throw MCPError.invalid(code + ": " + message)
                        }
                    }
                } catch {
                    result = ["isError": true, "content": [["type": "text", "text": String(describing: error)]]]
                }
            default: error = ["code": -32601, "message": "Method not found"]
            }
            var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
            if let error { response["error"] = error } else { response["result"] = result }
            if let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text); fflush(stdout) }
        }
    }
}

private enum MCPError: Error { case invalid(String) }
