// The menu under the prompt when a line starts with "/": the commands that
// match what's typed so far, narrowing with every key. Tab completes to the
// first one; Enter runs it.
//
// libedit has no menu of its own. It does let us supply the function that
// reads each key, called exactly when the editor is waiting for input: its
// line is up to date then and the screen is still. So the menu is redrawn
// there, under the prompt line, and the cursor put back.

import Foundation
@preconcurrency import CEditLine

enum SlashMenu {
    struct Command: Equatable {
        var name: String        // "/model"
        var arguments: String   // "[name|number]"
        var about: String
    }

    // MARK: - Pure (unit-tested)

    /// `Commands.help` rows ("/model [name|number]", "…") → menu commands.
    static func commands(from help: [(String, String)]) -> [Command] {
        help.map { usage, about in
            let parts = usage.split(separator: " ", maxSplits: 1).map(String.init)
            return Command(name: parts[0], arguments: parts.count > 1 ? parts[1] : "", about: about)
        }
    }

    /// The commands to offer for what's typed. Empty unless the line is a
    /// "/word" still being typed (no space yet). Names that start with the
    /// text come first, then names that merely contain it.
    static func matches(for typed: String, in commands: [Command]) -> [Command] {
        guard typed.hasPrefix("/"), !typed.contains(" ") else { return [] }
        let needle = typed.lowercased()
        let starts = commands.filter { $0.name.hasPrefix(needle) }
        guard needle.count > 1 else { return starts }
        let inner = String(needle.dropFirst())
        let contains = commands.filter { !$0.name.hasPrefix(needle) && $0.name.dropFirst().contains(inner) }
        return starts + contains
    }

    /// What Enter runs: the line as typed when its command exists (`known`
    /// has every name and alias), otherwise the first match's name in its
    /// place — "/mo sonnet" runs "/model sonnet".
    static func resolve(_ line: String, in commands: [Command], known: Set<String>) -> String {
        guard line.hasPrefix("/") else { return line }
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let name = parts[0].lowercased()
        if known.contains(name) { return line }
        guard let first = matches(for: name, in: commands).first else { return line }
        return parts.count > 1 ? first.name + " " + parts[1] : first.name
    }

    /// The menu's rows for a terminal `width` wide: the `selected` match
    /// marked (it's the one Tab and Enter take). At most `maxRows`; when there
    /// are more matches, the rows shown move to keep the selected one in view
    /// and the last row says how many aren't shown.
    static func rows(for matches: [Command], selected: Int = 0, width: Int, maxRows: Int = 10, color: Bool) -> [String] {
        guard !matches.isEmpty, width > 20 else { return [] }
        let overflow = matches.count > maxRows
        let size = overflow ? Swift.max(1, maxRows - 1) : matches.count
        let start = Swift.max(0, Swift.min(selected - size + 1, matches.count - size))
        let shown = Array(matches[start..<start + size])
        let nameWidth = shown.map { $0.name.count + ($0.arguments.isEmpty ? 0 : $0.arguments.count + 1) }.max() ?? 0
        var out: [String] = shown.enumerated().map { index, command in
            let marked = start + index == selected
            var line: Line = [Span(marked ? "❯ " : "  ", .c45, .bold),
                              Span(command.name, styles: marked ? [.c45, .bold] : [.c45])]
            if !command.arguments.isEmpty { line.append(Span(" " + command.arguments, .dim)) }
            line.append(Span(String(repeating: " ", count: Swift.max(0, 2 + nameWidth - (line.width - 2)))))
            line.append(Span(command.about, styles: marked ? [] : [.dim]))
            // One column short of the edge, so a full row never wraps.
            return (line.width > width - 1 ? line.fitted(to: width - 1) : line).rendered(color: color)
        }
        if overflow {
            out.append([Span("  … \(matches.count - size) more — ↑↓ or keep typing", .dim)].rendered(color: color))
        }
        return out
    }

    /// The selection after an arrow key: down is +1, up is −1, wrapping.
    static func moved(_ selected: Int, by step: Int, count: Int) -> Int {
        count > 0 ? ((selected + step) % count + count) % count : 0
    }

    /// The bytes that draw `rows` under the prompt line and put the cursor
    /// back where it was, replacing a menu of `previous` rows.
    static func drawing(rows: [String], previous: Int) -> String {
        let room = Swift.max(rows.count, previous)
        guard room > 0 else { return "" }
        let esc = "\u{1B}"
        // Index (ESC D) moves down a row in the same column and scrolls at the
        // bottom of the screen: room for the menu, the column kept.
        var out = String(repeating: "\(esc)D", count: room)
        out += "\(esc)[\(room)A"                           // back up to the prompt line
        out += "\(esc)7"                                     // remember the cursor
        out += "\r\n\(esc)[J"                                // clear everything under the prompt
        out += rows.joined(separator: "\r\n")
        out += "\(esc)8"                                     // and back
        return out
    }

    // MARK: - Hooked into libedit (LineEditor passes these to it)

    nonisolated(unsafe) private static var commands: [Command] = []
    nonisolated(unsafe) private static var shownRows = 0
    /// What the menu on screen was drawn for: the line and the selected row.
    nonisolated(unsafe) private static var shownFor: String?
    nonisolated(unsafe) private static var shownSelected = 0
    /// The matches on screen (empty when no menu is) and the selected one.
    nonisolated(unsafe) private static var current: [Command] = []
    nonisolated(unsafe) private static var selected = 0
    /// The line Esc closed the menu for; typing anything else brings it back.
    nonisolated(unsafe) private static var dismissedFor: String?
    /// ↑/↓ went to libedit's history: the line is a recalled one, and the
    /// arrows must keep going through history, so no menu until a key is typed.
    nonisolated(unsafe) private static var browsingHistory = false
    /// Bytes read while looking for an arrow key that turned out to be something else.
    nonisolated(unsafe) private static var pending: [UInt8] = []

    static func install(commands: [Command]) { self.commands = commands }

    /// Before each prompt.
    static func beginLine() {
        shownFor = nil
        shownRows = 0
        current = []
        selected = 0
        dismissedFor = nil
        browsingHistory = false
    }

    /// After a line is entered: remove whatever menu is still under it. The
    /// cursor is on the line below the input then, at its start.
    static func endLine() {
        current = []
        guard shownRows > 0 else { return }
        FileHandle.standardOutput.write(Data("\u{1B}[J".utf8))
        shownRows = 0
        shownFor = nil
    }

    /// The line being edited, and how many characters are left of the cursor.
    private static func currentLine(_ editor: OpaquePointer?) -> (text: String, cursor: Int) {
        guard let info = el_line(editor)?.pointee, let start = info.buffer, let end = info.lastchar, let cursor = info.cursor else { return ("", 0) }
        let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(start).assumingMemoryBound(to: UInt8.self), count: Swift.max(0, end - start))
        let before = String(decoding: bytes.prefix(Swift.max(0, cursor - start)), as: UTF8.self)
        return (String(decoding: bytes, as: UTF8.self), before.count)
    }

    /// Redraws the menu if the line or the selection changed since the last draw.
    private static func refresh(_ editor: OpaquePointer?) {
        let text = currentLine(editor).text
        if text != shownFor { selected = 0 }
        if text != dismissedFor { dismissedFor = nil }
        guard text != shownFor || selected != shownSelected else { return }
        shownFor = text
        current = text == dismissedFor || browsingHistory ? [] : matches(for: text, in: commands)
        selected = Swift.min(selected, Swift.max(0, current.count - 1))
        shownSelected = selected
        let maxRows = Swift.max(3, Swift.min(16, Console.height - 4))
        let rows = rows(for: current, selected: selected, width: Console.width, maxRows: maxRows, color: Console.stdoutColor)
        guard !rows.isEmpty || shownRows > 0 else { return }
        FileHandle.standardOutput.write(Data(drawing(rows: rows, previous: shownRows).utf8))
        shownRows = rows.count
    }

    /// libedit's key reader: bring the menu up to date, then wait for a key
    /// and hand back one whole character (UTF-8 put together here).
    /// 1 = a character, 0 = end of input.
    ///
    /// While the menu is open, some keys are the menu's and never reach
    /// libedit: ↑ and ↓ move the selection, Esc closes the menu. Enter with
    /// another row selected puts that command on the line first.
    static func readKey(_ editor: OpaquePointer?, _ out: UnsafeMutablePointer<wchar_t>?) -> Int32 {
        while true {
            refresh(editor)
            guard let first = nextByte() else { return 0 }
            if first == 27 {
                let after = arrowAfterEscape()
                if !current.isEmpty {
                    switch after {
                    case .up: selected = moved(selected, by: -1, count: current.count); continue
                    case .down: selected = moved(selected, by: 1, count: current.count); continue
                    case .escapeAlone: dismissedFor = shownFor; shownFor = nil; continue
                    case .other: break      // some other sequence: libedit gets it, from `pending`
                    }
                } else {
                    // No menu: the key is libedit's. Give it back what was read.
                    switch after {
                    case .up: pending.insert(contentsOf: Array("[A".utf8), at: 0); browsingHistory = true
                    case .down: pending.insert(contentsOf: Array("[B".utf8), at: 0); browsingHistory = true
                    case .escapeAlone, .other: break
                    }
                }
            } else if !lastByteWasGivenBack {
                if browsingHistory { browsingHistory = false; shownFor = nil }   // typing: the menu may come back
                if !current.isEmpty, first == 13 || first == 10 { takeSelected(editor, addSpace: false) }
            }
            let extra = first & 0xE0 == 0xC0 ? 1 : first & 0xF0 == 0xE0 ? 2 : first & 0xF8 == 0xF0 ? 3 : 0
            var scalar = extra > 0 ? UInt32(first) & (0xFF >> (UInt32(extra) + 2)) : UInt32(first)
            for _ in 0..<extra {
                guard let next = nextByte(), next & 0xC0 == 0x80 else { break }
                scalar = scalar << 6 | UInt32(next & 0x3F)
            }
            out?.pointee = wchar_t(bitPattern: scalar)
            return 1
        }
    }

    private enum AfterEscape { case up, down, escapeAlone, other }

    /// Called right after an Esc byte: is it an arrow key (ESC [ A, ESC O A,
    /// and B for down), Esc on its own, or the start of something else? Bytes
    /// read for something else are kept for libedit.
    private static func arrowAfterEscape() -> AfterEscape {
        guard inputWaiting(milliseconds: 40), let second = nextByte() else { return .escapeAlone }
        guard second == UInt8(ascii: "[") || second == UInt8(ascii: "O") else { pending.insert(second, at: 0); return .other }
        guard inputWaiting(milliseconds: 40), let third = nextByte() else { pending.insert(second, at: 0); return .other }
        switch third {
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        default: pending.insert(contentsOf: [second, third], at: 0); return .other
        }
    }

    /// An arrow key's bytes arrive together; a person's next key doesn't come this fast.
    private static func inputWaiting(milliseconds: Int32) -> Bool {
        if !pending.isEmpty { return true }
        var fds = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)]
        return poll(&fds, 1, milliseconds) > 0
    }

    /// Whether the byte `nextByte` just returned was one given back for
    /// libedit (the rest of an arrow key), not a new key press.
    nonisolated(unsafe) private static var lastByteWasGivenBack = false

    private static func nextByte() -> UInt8? {
        lastByteWasGivenBack = !pending.isEmpty
        if !pending.isEmpty { return pending.removeFirst() }
        var b: UInt8 = 0
        while true {
            let n = read(STDIN_FILENO, &b, 1)
            if n == 1 { return b }
            if n < 0 && errno == EINTR { continue }
            return nil
        }
    }

    /// Puts the selected command on the line in place of what was typed.
    /// Only with the cursor at the end of a "/word" — otherwise the line is
    /// left as it is. Returns whether it changed the line.
    @discardableResult
    private static func takeSelected(_ editor: OpaquePointer?, addSpace: Bool) -> Bool {
        let (text, cursor) = currentLine(editor)
        guard cursor == text.count, current.indices.contains(selected) else { return false }
        let command = current[selected]
        let replacement = command.name + (addSpace && !command.arguments.isEmpty ? " " : "")
        guard replacement != text else { return false }
        el_deletestr(editor, Int32(cursor))
        _ = el_insertstr(editor, replacement)
        return true
    }

    /// Tab: the "/word" becomes the selected command (and a space, when the
    /// command takes arguments). Otherwise nothing.
    static func complete(_ editor: OpaquePointer?) -> UInt8 {
        if current.isEmpty { refresh(editor) }
        return UInt8(takeSelected(editor, addSpace: true) ? sak_cc_refresh() : sak_cc_norm())
    }
}
