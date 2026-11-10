// The chat's welcome panel and the status rule above each prompt.
//
// Everything here is pure: it takes what to show and a width, and returns
// lines. main.swift gathers the facts and prints them; the tests check the
// layout (every row exactly as wide as the box, at any width, with or
// without colour).

import Foundation

/// A piece of text and how it's styled. Width is measured on the text alone.
struct Span: Equatable {
    var text: String
    var styles: [Style] = []
    init(_ text: String, _ styles: Style...) { self.text = text; self.styles = styles }
    init(_ text: String, styles: [Style]) { self.text = text; self.styles = styles }
}

typealias Line = [Span]

extension Array where Element == Span {
    var width: Int { reduce(0) { $0 + $1.text.count } }

    /// Exactly `width` columns: cut with an ellipsis, or padded with spaces.
    func fitted(to width: Int) -> Line {
        guard width > 0 else { return [] }
        var out: Line = []
        var left = width
        for span in self {
            if span.text.count <= left {
                out.append(span); left -= span.text.count
            } else {
                // No room for the whole span: keep what fits, end with "…".
                let keep = Swift.max(0, left - 1)
                out.append(Span(String(span.text.prefix(keep)) + "…", styles: span.styles))
                left = 0
            }
            if left == 0 { break }
        }
        if left > 0 { out.append(Span(String(repeating: " ", count: left))) }
        return out
    }

    func rendered(color: Bool) -> String {
        map { span in
            guard color, !span.styles.isEmpty, !span.text.isEmpty else { return span.text }
            return "\u{1B}[\(span.styles.map(\.rawValue).joined(separator: ";"))m\(span.text)\u{1B}[0m"
        }.joined()
    }
}

enum Welcome {
    /// What the panel shows. Gathered in main.swift.
    struct Info {
        var version: String
        var model: String
        var provider: String
        var folder: String          // already shortened with ~
        var branch: String?
        var mode: String            // "asks before changes", "read-only", "auto mode"
        var window: Int             // context window, tokens
        var notes: [(label: String, value: String)] = []   // ("notes", "naseem/"), ("config", "~/.config/sak/.env")
        var toolGroups: [(label: String, names: [String])] = []
        /// All tools, MCP ones included (a server shows as one entry with a count).
        var toolCount = 0
        var skills: [String] = []
        var warnings: [String] = [] // an MCP server that didn't connect
    }

    static let logo = [
        "███████  █████  ██   ██",
        "██      ██   ██ ██  ██ ",
        "███████ ███████ █████  ",
        "     ██ ██   ██ ██  ██ ",
        "███████ ██   ██ ██   ██",
    ]
    /// Top to bottom: cyan into blue into violet.
    static let logoColors: [Style] = [.c51, .c45, .c39, .c33, .c63]

    /// The panel, as lines exactly `width` wide (at least 44).
    static func panel(_ info: Info, width requested: Int, color: Bool) -> [String] {
        let width = Swift.max(44, Swift.min(requested, 104))
        let inner = width - 4                       // "│ " … " │"
        let twoColumns = inner >= 72
        let leftWidth = twoColumns ? 34 : inner
        let rightWidth = twoColumns ? inner - leftWidth - 3 : inner   // " │ " between

        // Left: the wordmark and where you are.
        var left: [Line] = zip(logo, logoColors).map { [Span($0, $1, .bold)] }
        left.append([Span("a coding agent for your terminal", .dim)])
        left.append([])
        func fact(_ label: String, _ value: String, _ style: Style? = nil) -> Line {
            [Span(label.padding(toLength: 8, withPad: " ", startingAt: 0), .dim), Span(value, styles: style.map { [$0] } ?? [])]
        }
        left.append(fact("model", info.model, .c45))
        left.append(fact("via", info.provider))
        left.append(fact("folder", info.folder))
        if let branch = info.branch { left.append(fact("branch", branch)) }
        left.append(fact("mode", info.mode, info.mode.hasPrefix("auto") ? .yellow : nil))
        left.append(fact("window", "\(short(info.window)) tokens"))
        for note in info.notes { left.append(fact(note.label, note.value)) }

        // Right: what the agent can use.
        var right: [Line] = []
        let toolCount = info.toolCount
        right.append([Span("Tools", .bold)])
        let labelWidth = (info.toolGroups.map(\.label.count).max() ?? 4) + 2
        for group in info.toolGroups {
            let rows = wrap(group.names, width: rightWidth - labelWidth, maxLines: 2)
            for (i, row) in rows.enumerated() {
                let label = i == 0 ? group.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
                                   : String(repeating: " ", count: labelWidth)
                right.append([Span(label, .c37), Span(row)])
            }
        }
        if !info.skills.isEmpty {
            right.append([])
            right.append([Span("Skills", .bold)])
            for row in wrap(info.skills, width: rightWidth, maxLines: 3) { right.append([Span(row)]) }
        }
        for warning in info.warnings {
            right.append([])
            right.append([Span("⚠ " + warning, .yellow)])
        }

        let border: [Style] = [.c37]
        func framed(_ content: Line) -> String {
            ([Span("│ ", styles: border)] + content + [Span(" │", styles: border)]).rendered(color: color)
        }

        var lines: [String] = []
        let title = " sak \(info.version) "
        let ruleAfterTitle = String(repeating: "─", count: Swift.max(0, width - 3 - title.count))
        lines.append([Span("╭─", styles: border), Span(title, .bold), Span(ruleAfterTitle + "╮", styles: border)].rendered(color: color))

        if twoColumns {
            for i in 0..<Swift.max(left.count, right.count) {
                let l = (i < left.count ? left[i] : []).fitted(to: leftWidth)
                let r = (i < right.count ? right[i] : []).fitted(to: rightWidth)
                lines.append(framed(l + [Span(" │ ", styles: border + [.dim])] + r))
            }
        } else {
            for l in left { lines.append(framed(l.fitted(to: inner))) }
            lines.append(framed(Line().fitted(to: inner)))
            for r in right { lines.append(framed(r.fitted(to: inner))) }
        }

        lines.append(framed(Line().fitted(to: inner)))
        let footer: Line = [
            Span("\(toolCount) tool\(toolCount == 1 ? "" : "s")", .c45),
            Span(" · ", .dim),
            Span("\(info.skills.count) skill\(info.skills.count == 1 ? "" : "s")", .c45),
            Span(twoColumns ? " · /help for commands · Ctrl-C stops a request · Ctrl-D quits" : " · /help · Ctrl-C stops · Ctrl-D quits", .dim),
        ]
        lines.append(framed(footer.fitted(to: inner)))
        lines.append([Span("╰" + String(repeating: "─", count: width - 2) + "╯", styles: border)].rendered(color: color))
        return lines
    }

    /// The rule above each prompt: model, how full the context is, where you are.
    ///   ── kimi-k2.6:cloud · ctx 7.2K/262K ▰▱▱▱▱▱▱▱▱▱ 3% · sak-cli (main) · asks before changes ────
    static func statusRule(model: String, used: Int, window: Int, folder: String, branch: String?,
                           mode: String, width requested: Int, color: Bool) -> String {
        let width = Swift.max(20, requested)
        let fraction = window > 0 ? Swift.min(1, Double(used) / Double(window)) : 0
        let cells = 10
        let filled = used > 0 ? Swift.max(1, Int((fraction * Double(cells)).rounded())) : 0
        let barStyle: Style = fraction >= 0.85 ? .red : fraction >= 0.6 ? .yellow : .c45
        let sep = Span(" · ", .dim)
        var line: Line = [
            Span("── ", .c37),
            Span(model, .c45, .bold), sep,
            Span("ctx \(short(used))/\(short(window)) ", .dim),
            Span(String(repeating: "▰", count: filled), barStyle),
            Span(String(repeating: "▱", count: cells - filled), .dim),
            Span(" \(Int((fraction * 100).rounded()))%", .dim), sep,
            Span(folder + (branch.map { " (\($0))" } ?? ""), .dim), sep,
            Span(mode, styles: mode.hasPrefix("auto") ? [.yellow] : [.dim]),
            Span(" "),
        ]
        if line.width >= width {
            line = line.fitted(to: width)
        } else {
            line.append(Span(String(repeating: "─", count: width - line.width), .c37))
        }
        return line.rendered(color: color)
    }

    // MARK: - Helpers (pure)

    /// 7234 → "7.2K", 262144 → "262K", 1_000_000 → "1M".
    static func short(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<10_000:
            let tenths = (Double(n) / 100).rounded() / 10
            return tenths == tenths.rounded() ? "\(Int(tenths))K" : "\(tenths)K"
        case ..<1_000_000: return "\(Int((Double(n) / 1000).rounded()))K"
        default:
            let tenths = (Double(n) / 100_000).rounded() / 10
            return tenths == tenths.rounded() ? "\(Int(tenths))M" : "\(tenths)M"
        }
    }

    /// Names joined with ", " into rows no wider than `width`; past
    /// `maxLines` the rest become "+N more".
    static func wrap(_ names: [String], width: Int, maxLines: Int) -> [String] {
        guard !names.isEmpty, width > 0 else { return [] }
        var rows: [String] = []
        var current = ""
        var index = 0
        while index < names.count {
            let name = names[index]
            let remaining = names.count - index - 1
            let isLastRow = rows.count == maxLines - 1
            // On the last row, leave room to say how many are left.
            // Other rows keep one column for the comma that says "continues".
            let reserve = isLastRow ? (remaining > 0 ? ", +\(remaining) more".count : 0) : 1
            let candidate = current.isEmpty ? name : current + ", " + name
            if candidate.count + reserve <= width {
                current = candidate
                index += 1
            } else if isLastRow {
                break
            } else if current.isEmpty {
                // One name wider than the row: it takes the row, cut by the caller.
                rows.append(name); index += 1
            } else {
                rows.append(current); current = ""
            }
        }
        let left = names.count - index
        if left > 0 { current += current.isEmpty ? "+\(left) more" : ", +\(left) more" }
        if !current.isEmpty { rows.append(current) }
        // A row that continues on the next ends with a comma.
        for i in rows.indices.dropLast() where rows[i].count < width { rows[i] += "," }
        return rows
    }

    /// Groups tool names the way the panel shows them. MCP tools go under
    /// their server, as a count: a browser server alone brings dozens.
    static func group(tools: [String], mcpServerOf: [String: String]) -> [(label: String, names: [String])] {
        let known: [(String, [String])] = [
            ("files", ["list_dir", "search_files", "read_file", "edit_file", "write_file", "patch_file"]),
            ("shell", ["run_shell", "run_python"]),
            ("web", ["web_search", "fetch_url"]),
            ("skills", ["use_skill", "learn_skill", "import_skill"]),
        ]
        var rest = Set(tools)
        var groups: [(label: String, names: [String])] = []
        for (label, names) in known {
            let present = names.filter(rest.contains)
            if !present.isEmpty { groups.append((label, present)); rest.subtract(present) }
        }
        var perServer: [String: Int] = [:]
        for name in rest { if let server = mcpServerOf[name] { perServer[server, default: 0] += 1 } }
        rest = rest.filter { mcpServerOf[$0] == nil }
        if !rest.isEmpty { groups.append(("more", rest.sorted())) }
        let servers = perServer.keys.sorted().map { "\($0) (\(perServer[$0]!) tool\(perServer[$0]! == 1 ? "" : "s"))" }
        if !servers.isEmpty { groups.append(("mcp", servers)) }
        return groups
    }

    /// "/Users/me/projects/x" → "~/projects/x"; a long path keeps its ends.
    static func shortPath(_ path: String, home: String, max: Int = 40) -> String {
        var p = path
        if p == home { p = "~" } else if p.hasPrefix(home + "/") { p = "~" + p.dropFirst(home.count) }
        guard p.count > max else { return p }
        let parts = p.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 2 else { return p }
        return "\(p.hasPrefix("~") ? "~" : "")/…/\(parts.suffix(2).joined(separator: "/"))"
    }

    /// The branch from `.git/HEAD`, without running git. nil outside a repo
    /// or on a detached HEAD.
    static func gitBranch(in folder: URL) -> String? {
        guard let head = try? String(contentsOf: folder.appendingPathComponent(".git/HEAD"), encoding: .utf8) else { return nil }
        let prefix = "ref: refs/heads/"
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
    }
}
