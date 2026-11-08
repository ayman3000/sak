// Terminal output, the line editor, and Ctrl-C handling.

import Foundation
import CEditLine

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
}

enum Style: String, Sendable {
    case dim = "2", bold = "1", cyan = "36", yellow = "33", red = "31", green = "32", magenta = "35"
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

    static func start() {
        try? FileManager.default.createDirectory(atPath: (historyFile as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        _ = read_history(historyFile)
    }

    /// nil on Ctrl-D.
    static func readLine(prompt: String) -> String? {
        guard let raw = CEditLine.readline(prompt) else { return nil }
        defer { free(raw) }
        let line = String(cString: raw)
        if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            _ = add_history(raw)
            _ = write_history(historyFile)
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

    func install(console: Console) {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let handler = self.lock.withLock { self.onInterrupt }
            if let handler {
                console.progress("\n⏹ stopping…", .yellow)
                handler()
            } else {
                console.out("\n(Ctrl-D or /exit to quit)")
            }
        }
        source.resume()
        self.source = source
    }

    /// Until `disarm()`, Ctrl-C calls `cancel` instead of printing a hint.
    func arm(_ cancel: @escaping @Sendable () -> Void) { lock.withLock { onInterrupt = cancel } }
    func disarm() { lock.withLock { onInterrupt = nil } }
}
