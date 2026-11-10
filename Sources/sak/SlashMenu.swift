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

    /// The menu's rows for a terminal `width` wide: the first match marked
    /// (it's the one Tab and Enter take), at most `maxRows`, then how many
    /// more there are.
    static func rows(for matches: [Command], width: Int, maxRows: Int = 10, color: Bool) -> [String] {
        guard !matches.isEmpty, width > 20 else { return [] }
        let shown = matches.count > maxRows ? Array(matches.prefix(maxRows - 1)) : matches
        let nameWidth = shown.map { $0.name.count + ($0.arguments.isEmpty ? 0 : $0.arguments.count + 1) }.max() ?? 0
        var out: [String] = shown.enumerated().map { index, command in
            let first = index == 0
            var line: Line = [Span(first ? "❯ " : "  ", .c45, .bold),
                              Span(command.name, styles: first ? [.c45, .bold] : [.c45])]
            if !command.arguments.isEmpty { line.append(Span(" " + command.arguments, .dim)) }
            line.append(Span(String(repeating: " ", count: Swift.max(0, 2 + nameWidth - (line.width - 2)))))
            line.append(Span(command.about, .dim))
            // One column short of the edge, so a full row never wraps.
            return (line.width > width - 1 ? line.fitted(to: width - 1) : line).rendered(color: color)
        }
        if matches.count > shown.count {
            out.append([Span("  … \(matches.count - shown.count) more — keep typing", .dim)].rendered(color: color))
        }
        return out
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
    nonisolated(unsafe) private static var shownFor: String?

    static func install(commands: [Command]) { self.commands = commands }

    /// Before each prompt.
    static func beginLine() {
        shownFor = nil
        shownRows = 0
    }

    /// After a line is entered: remove whatever menu is still under it. The
    /// cursor is on the line below the input then, at its start.
    static func endLine() {
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

    /// Redraws the menu if the line changed since the last draw.
    private static func refresh(_ editor: OpaquePointer?) {
        let text = currentLine(editor).text
        guard text != shownFor else { return }
        shownFor = text
        let maxRows = Swift.max(3, Swift.min(16, Console.height - 4))
        let rows = rows(for: matches(for: text, in: commands), width: Console.width, maxRows: maxRows, color: Console.stdoutColor)
        guard !rows.isEmpty || shownRows > 0 else { return }
        FileHandle.standardOutput.write(Data(drawing(rows: rows, previous: shownRows).utf8))
        shownRows = rows.count
    }

    /// libedit's key reader: bring the menu up to date, then wait for a key
    /// and hand back one whole character (UTF-8 put together here).
    /// 1 = a character, 0 = end of input.
    static func readKey(_ editor: OpaquePointer?, _ out: UnsafeMutablePointer<wchar_t>?) -> Int32 {
        refresh(editor)
        guard let first = readByte() else { return 0 }
        let extra = first & 0xE0 == 0xC0 ? 1 : first & 0xF0 == 0xE0 ? 2 : first & 0xF8 == 0xF0 ? 3 : 0
        var scalar = extra > 0 ? UInt32(first) & (0xFF >> (UInt32(extra) + 2)) : UInt32(first)
        for _ in 0..<extra {
            guard let next = readByte(), next & 0xC0 == 0x80 else { break }
            scalar = scalar << 6 | UInt32(next & 0x3F)
        }
        out?.pointee = wchar_t(bitPattern: scalar)
        return 1
    }

    private static func readByte() -> UInt8? {
        var b: UInt8 = 0
        while true {
            let n = read(STDIN_FILENO, &b, 1)
            if n == 1 { return b }
            if n < 0 && errno == EINTR { continue }
            return nil
        }
    }

    /// Tab: a "/word" with the cursor at its end becomes the first match
    /// (and a space, when the command takes arguments). Otherwise nothing.
    static func complete(_ editor: OpaquePointer?) -> UInt8 {
        let (text, cursor) = currentLine(editor)
        guard cursor == text.count, let first = matches(for: text, in: commands).first else { return UInt8(sak_cc_norm()) }
        el_deletestr(editor, Int32(cursor))
        _ = el_insertstr(editor, first.name + (first.arguments.isEmpty ? "" : " "))
        return UInt8(sak_cc_refresh())
    }
}
