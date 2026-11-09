// MCP servers — the one extension point. `~/.config/sak/mcp.json` (or
// `./.sak/mcp.json` in a project) lists servers in the same shape Claude
// Code, Claude Desktop and Cursor use, so a config can be pasted across:
//
//   { "mcpServers": {
//       "chrome-devtools": { "command": "npx", "args": ["-y", "chrome-devtools-mcp@latest", "--isolated"] },
//       "docs":            { "url": "https://example.com/mcp" } } }
//
// Naseem's servers come along too (SAK_NASEEM=0 turns that off): the enabled
// ones from its settings, read-only, except those that need a sign-in —
// their tokens live in Naseem. A same-named mcp.json entry wins.
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
        /// "mcp.json" or "Naseem" — for the banner.
        var source: String = "mcp.json"
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

    /// Naseem's settings file; its `settings.mcpServers` value is JSON (an array of
    /// servers) stored as data.
    static var naseemSettings: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.ayman3000.Naseem.plist")
    }

    /// Pure — unit-tested. Naseem's server list → servers sak can start:
    /// enabled, no sign-in needed. Returns the names it skipped for a sign-in.
    static func parseNaseem(_ json: Data) -> (servers: [Server], needSignIn: [String]) {
        guard let list = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] else { return ([], []) }
        var out: [Server] = [], skipped: [String] = []
        for s in list {
            guard let name = (s["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  (s["enabled"] as? Bool) != false else { continue }
            if (s["signIn"] as? Bool) == true { skipped.append(name); continue }
            if let command = (s["command"] as? String)?.trimmingCharacters(in: .whitespaces), !command.isEmpty {
                // A flag typed in a text field can arrive with a dash the keyboard "corrected".
                let args = ((s["args"] as? [Any])?.compactMap { $0 as? String } ?? []).map { a in
                    a.hasPrefix("\u{2014}") || a.hasPrefix("\u{2013}") ? "--" + a.dropFirst() : a
                }
                let env = (s["env"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
                out.append(Server(name: name, config: .stdio(command: command, args: args, env: env), source: "Naseem"))
            } else if let raw = s["endpoint"] as? String, let url = URL(string: raw), !raw.isEmpty {
                out.append(Server(name: name, config: .http(url), source: "Naseem"))
            }
        }
        return (out, skipped)
    }

    /// Naseem's servers from its settings file; empty when Naseem isn't there.
    static func fromNaseem(settingsFile: URL = naseemSettings) -> (servers: [Server], needSignIn: [String]) {
        guard let data = try? Data(contentsOf: settingsFile),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return ([], []) }
        if let json = plist["settings.mcpServers"] as? Data { return parseNaseem(json) }
        if let text = plist["settings.mcpServers"] as? String { return parseNaseem(Data(text.utf8)) }
        return ([], [])
    }

    /// The config files, project first: `./.sak/mcp.json`, then `~/.config/sak/mcp.json`.
    static func files(projectDirectory: URL) -> [URL] {
        [projectDirectory.appendingPathComponent(".sak/mcp.json"), Settings.configDirectory.appendingPathComponent("mcp.json")]
    }

    /// What `connect` found: tools to register and lines for the banner / `/mcp`.
    struct Connected {
        var tools: [any AgentTool] = []
        var lines: [String] = []
        /// One manager per server, kept alive for the session.
        var managers: [MCPManager] = []
        /// Tool name → the server it came from (for "allow all of this server").
        var serverOf: [String: String] = [:]
        var toolCount: Int { tools.count }
    }

    /// Connects every configured server (a few seconds at most each) and
    /// bridges its tools. A server that fails is a line in the report, not a
    /// reason to stop. Returns an empty result when no file exists.
    static func connect(projectDirectory: URL, readOnly: Bool, withNaseem: Bool = true) async -> Connected {
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
        if withNaseem {
            let (theirs, needSignIn) = fromNaseem()
            for s in theirs where !seen.contains(s.name) { servers.append(s); seen.insert(s.name) }
            if !needSignIn.isEmpty {
                out.lines.append("Naseem's \(needSignIn.joined(separator: ", ")) need\(needSignIn.count == 1 ? "s" : "") a sign-in — use \(needSignIn.count == 1 ? "it" : "them") in Naseem")
            }
        }
        guard !servers.isEmpty else { return out }
        var connectedNames: [String] = []
        var bridgedCount = 0
        for s in servers {
            let config: MCPClientConfig = switch s.config {
            case let .stdio(command, args, env): .stdio(command: command, args: args, env: env.isEmpty ? nil : env)
            case let .http(url): .http(endpoint: url)
            }
            let manager = MCPManager(roots: [projectDirectory], connectTimeout: 15)
            do {
                try await manager.connect(config)
            } catch {
                out.lines.append("\(s.name): couldn't connect — \(oneLine(String(describing: error), max: 120))")
                continue
            }
            out.managers.append(manager)
            let serverName = await manager.connectedServers().first ?? s.name
            connectedNames.append(serverName)
            let bridged = (try? await manager.bridgedTools()) ?? []
            bridgedCount += bridged.count
            for tool in bridged {
                guard let b = tool as? MCPToolBridge else { continue }
                let readsOnly = b.readOnlyHint == true
                if readOnly && !readsOnly { continue }
                out.tools.append(GatedMCPTool(inner: b, requiresConfirmation: !readsOnly, server: serverName))
                out.serverOf[b.name] = serverName
            }
        }
        if !connectedNames.isEmpty {
            // Servers name themselves on connect (not always as the config does), so
            // the source is said once: all from Naseem, all from mcp.json, or both.
            let sources = Set(servers.map(\.source))
            let origin = sources == ["Naseem"] ? "Naseem's " : sources.count > 1 ? "mcp.json and Naseem: " : ""
            out.lines.insert("\(out.tools.count) MCP tool\(out.tools.count == 1 ? "" : "s") from \(origin)\(connectedNames.joined(separator: ", "))"
                             + (readOnly && out.tools.count < bridgedCount ? " (read-only ones; \(bridgedCount - out.tools.count) left out)" : ""), at: 0)
        }
        return out
    }
}

/// An MCP tool with sak's rule applied: read-only tools run, the rest ask.
struct GatedMCPTool: AgentTool {
    let inner: MCPToolBridge
    let requiresConfirmation: Bool
    let server: String
    var name: String { inner.name }
    var description: String { inner.description }
    var parameters: ToolParameters { inner.parameters }
    var isReadOnly: Bool { !requiresConfirmation }
    func execute(parameters: [String: Any]) async throws -> AgentToolResult { try await inner.execute(parameters: parameters) }
}
