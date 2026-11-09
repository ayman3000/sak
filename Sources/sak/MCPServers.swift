// MCP servers — the one extension point. `~/.config/sak/mcp.json` (or
// `./.sak/mcp.json` in a project) lists servers in the same shape Claude
// Code, Claude Desktop and Cursor use, so a config can be pasted across:
//
//   { "mcpServers": {
//       "chrome-devtools": { "command": "npx", "args": ["-y", "chrome-devtools-mcp@latest", "--isolated"] },
//       "docs":            { "url": "https://example.com/mcp" } } }
//
// Each server's tools join the agent's. A tool the server marks read-only
// runs like read_file; any other asks first, like edit_file and run_shell
// (-y and /yes apply). --read-only keeps only the read-only ones. Every
// server adds its tool schemas to every prompt — a cost worth knowing.

import Foundation
import SwiftAgentKit
import SwiftAgentKitMCP

enum MCPServers {
    struct Server: Equatable {
        var name: String
        var config: Config
        enum Config: Equatable {
            case stdio(command: String, args: [String], env: [String: String])
            case http(URL)
        }
    }

    enum ParseError: Error, CustomStringConvertible {
        case notJSON, noServers, badServer(String)
        var description: String {
            switch self {
            case .notJSON: "mcp.json isn't valid JSON"
            case .noServers: "mcp.json has no \"mcpServers\" object"
            case .badServer(let n): "server \"\(n)\" needs a \"command\" or a \"url\""
            }
        }
    }

    /// Pure — unit-tested. The Claude-style file → servers, in name order.
    static func parse(_ data: Data) throws -> [Server] {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notJSON }
        guard let servers = (top["mcpServers"] ?? top["servers"]) as? [String: Any] else { throw ParseError.noServers }
        return try servers.keys.sorted().map { name in
            guard let s = servers[name] as? [String: Any] else { throw ParseError.badServer(name) }
            if (s["disabled"] as? Bool) == true || (s["enabled"] as? Bool) == false { return nil }
            if let command = (s["command"] as? String)?.trimmingCharacters(in: .whitespaces), !command.isEmpty {
                let args = (s["args"] as? [Any])?.compactMap { $0 as? String } ?? []
                let env = (s["env"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
                return Server(name: name, config: .stdio(command: command, args: args, env: env))
            }
            if let raw = (s["url"] ?? s["endpoint"]) as? String, let url = URL(string: raw) {
                return Server(name: name, config: .http(url))
            }
            throw ParseError.badServer(name)
        }.compactMap { $0 }
    }

    /// The config files, project first: `./.sak/mcp.json`, then `~/.config/sak/mcp.json`.
    static func files(projectDirectory: URL) -> [URL] {
        [projectDirectory.appendingPathComponent(".sak/mcp.json"), Settings.configDirectory.appendingPathComponent("mcp.json")]
    }

    /// What `connect` found: tools to register and lines for the banner / `/mcp`.
    struct Connected {
        var tools: [any AgentTool] = []
        var lines: [String] = []
        var manager: MCPManager?
        var toolCount: Int { tools.count }
    }

    /// Connects every configured server (a few seconds at most each) and
    /// bridges its tools. A server that fails is a line in the report, not a
    /// reason to stop. Returns an empty result when no file exists.
    static func connect(projectDirectory: URL, readOnly: Bool) async -> Connected {
        var out = Connected()
        var servers: [Server] = []
        var seen = Set<String>()
        for file in files(projectDirectory: projectDirectory) {
            guard let data = try? Data(contentsOf: file) else { continue }
            do {
                for s in try parse(data) where !seen.contains(s.name) { servers.append(s); seen.insert(s.name) }
            } catch {
                out.lines.append("\(file.path): \(error)")
            }
        }
        guard !servers.isEmpty else { return out }
        let manager = MCPManager(roots: [projectDirectory], connectTimeout: 15)
        out.manager = manager
        for s in servers {
            let config: MCPClientConfig = switch s.config {
            case let .stdio(command, args, env): .stdio(command: command, args: args, env: env.isEmpty ? nil : env)
            case let .http(url): .http(endpoint: url)
            }
            do {
                try await manager.connect(config)
            } catch {
                out.lines.append("\(s.name): couldn't connect — \(oneLine(String(describing: error), max: 120))")
            }
        }
        let bridged = (try? await manager.bridgedTools()) ?? []
        let wrapped = bridged.compactMap { tool -> (any AgentTool)? in
            guard let b = tool as? MCPToolBridge else { return tool }
            let readsOnly = b.readOnlyHint == true
            if readOnly && !readsOnly { return nil }
            return GatedMCPTool(inner: b, requiresConfirmation: !readsOnly)
        }
        out.tools = wrapped
        let connected = await manager.connectedServers()
        if !connected.isEmpty {
            out.lines.insert("\(wrapped.count) MCP tool\(wrapped.count == 1 ? "" : "s") from \(connected.joined(separator: ", "))"
                             + (readOnly && wrapped.count < bridged.count ? " (read-only ones; \(bridged.count - wrapped.count) left out)" : ""), at: 0)
        }
        return out
    }
}

/// An MCP tool with sak's rule applied: read-only tools run, the rest ask.
struct GatedMCPTool: AgentTool {
    let inner: MCPToolBridge
    let requiresConfirmation: Bool
    var name: String { inner.name }
    var description: String { inner.description }
    var parameters: ToolParameters { inner.parameters }
    var isReadOnly: Bool { !requiresConfirmation }
    func execute(parameters: [String: Any]) async throws -> AgentToolResult { try await inner.execute(parameters: parameters) }
}
