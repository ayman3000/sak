// Terminal output, the line editor, and Ctrl-C handling.

import Foundation
@preconcurrency import CEditLine

/// Where sak writes. The answer goes to stdout; progress (tool calls, notes)
/// goes to stdout in a chat and to stderr in one-shot mode, so
/// `sak "…" > answer.txt` captures only the answer.
struct Console: Sendable {
    var progressToStderr = false
    var quiet = false

    static let stdoutColor = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    static let stderrColor = isatty(STDERR_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    func out(_ text: String, newline: Bool = true) {
        FileHandle.standardOutput.write(Data((text + (newline ? "\n" : "")).utf8))
    }

    /// A progress line, styled for whichever stream it lands on.
    func progress(_ text: String, _ style: Style = .dim) {
        guard !quiet else { return }
        let color = progressToStderr ? Self.stderrColor : Self.stdoutColor
        let line = (color ? style.apply(text) : text) + "\n"
        (progressToStderr ? FileHandle.standardError : FileHandle.standardOutput).write(Data(line.utf8))
    }

    func error(_ text: String) {
        let line = (Self.stderrColor ? Style.red.apply(text) : text) + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Styled text for stdout (chat mode headers, lists).
    func styled(_ text: String, _ style: Style) -> String {
        Self.stdoutColor ? style.apply(text) : text
    }

    /// The line the person just typed, shown once more in bold so it stands
    /// apart from the answer under it: the editor's echo is one line up.
    func restyleInput(_ line: String, lines: Int) {
        guard Self.stdoutColor, lines == 1 else { return }
        out("\u{1B}[1A\u{1B}[2K" + Style.c45.apply("❯ ") + Style.bold.apply(line), newline: true)
    }

    /// The terminal's height in rows; 24 when stdout isn't a terminal.
    static var height: Int {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0 else { return 24 }
        return Int(size.ws_row)
    }

    /// The terminal's width in columns; 80 when stdout isn't a terminal.
    static var width: Int {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return 80 }
        return Int(size.ws_col)
    }
}

enum Style: String, Sendable {
    case dim = "2", bold = "1", italic = "3", cyan = "36", yellow = "33", red = "31", green = "32", magenta = "35"
    /// 256-colour shades for the welcome panel and status rule: the logo's
    /// cyan → blue → violet, and a muted teal for borders and labels.
    case c51 = "38;5;51", c45 = "38;5;45", c39 = "38;5;39", c33 = "38;5;33", c63 = "38;5;63", c37 = "38;5;37"
    /// Inline code: cyan, like the tool names.
    static let code = Style.cyan
    func apply(_ text: String) -> String { "\u{1B}[\(rawValue)m\(text)\u{1B}[0m" }
}

func oneLine(_ text: String, max: Int = 100) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ")
    return flat.count > max ? String(flat.prefix(max)) + "…" : flat
}

// MARK: - Line editor

/// Prompt input with arrow keys, history (saved between runs) and Ctrl-R, via libedit.
enum LineEditor {
    static let historyFile = Settings.globalFile.deletingLastPathComponent().appendingPathComponent("history").path

    nonisolated(unsafe) private static var editor: OpaquePointer?
    nonisolated(unsafe) private static var history: OpaquePointer?
    nonisolated(unsafe) private static var prompt: UnsafeMutablePointer<CChar>?

    static func start() {
        try? FileManager.default.createDirectory(atPath: (historyFile as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        // libedit reads and shows UTF-8 only in a UTF-8 locale. Take the
        // user's; if that isn't UTF-8 (LANG unset, as under some launchers),
        // use UTF-8 for characters anyway — a Mac terminal is.
        setlocale(LC_CTYPE, "")
        if String(cString: nl_langinfo(CODESET)) != "UTF-8" { setlocale(LC_CTYPE, "UTF-8") }
        history = sak_history_new(historyFile)
        editor = sak_editor_new(history,
                                { _ in LineEditor.prompt },
                                { editor, out in SlashMenu.readKey(editor, out) },
                                { editor, _ in SlashMenu.complete(editor) })
    }

    /// After Ctrl-C at the prompt: editing mode again, prompt and line redrawn.
    static func restoreAfterInterrupt() {
        guard reading, let editor else { return }
        SlashMenu.beginLine()
        sak_editor_restore(editor)
    }

    nonisolated(unsafe) private static var reading = false

    /// nil on Ctrl-D.
    static func readLine(prompt text: String) -> String? {
        free(prompt)
        prompt = strdup(text)
        SlashMenu.beginLine()
        reading = true
        defer { reading = false; SlashMenu.endLine() }
        var count: Int32 = 0
        guard let raw = el_gets(editor, &count), count > 0 else { return nil }
        var line = String(cString: raw)
        if line.hasSuffix("\n") { line.removeLast() }
        if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            sak_history_add(history, line, historyFile)
        }
        return line
    }
}

// MARK: - Ctrl-C

/// Ctrl-C during a request stops that request; at the prompt it explains how to quit.
final class Interrupts: @unchecked Sendable {
    private let lock = NSLock()
    private var onInterrupt: (@Sendable () -> Void)?
    private var source: DispatchSourceSignal?
    private var stopping = false
    private var lastHint = Date.distantPast

    func install(console: Console) {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let (handler, again) = self.lock.withLock { (self.onInterrupt, self.stopping) }
            if let handler {
                if again {
                    // The first Ctrl-C asked the run to stop; a tool call that
                    // doesn't come back (a page that never loads) would keep us
                    // here. The second one quits sak.
                    console.progress("\n⏹ quitting (a tool call didn't return)", .yellow)
                    exit(130)
                }
                self.lock.withLock { self.stopping = true }
                console.progress("\n⏹ stopping… (Ctrl-C again quits sak)", .yellow)
                handler()
            } else {
                // libedit passes the signal on after tidying the terminal, so
                // one Ctrl-C at the prompt arrives twice: say it once.
                let now = Date()
                let repeated = self.lock.withLock { () -> Bool in
                    defer { self.lastHint = now }
                    return now.timeIntervalSince(self.lastHint) < 0.3
                }
                if !repeated {
                    console.out("\n(Ctrl-D or /exit to quit)")
                    // libedit left the terminal in plain mode for the signal;
                    // once it has finished, bring the prompt and editing back.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { LineEditor.restoreAfterInterrupt() }
                }
            }
        }
        source.resume()
        self.source = source
    }

    /// Until `disarm()`, Ctrl-C calls `cancel` instead of printing a hint.
    func arm(_ cancel: @escaping @Sendable () -> Void) { lock.withLock { onInterrupt = cancel; stopping = false } }
    func disarm() { lock.withLock { onInterrupt = nil; stopping = false } }
}
