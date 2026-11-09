// Light Markdown for the terminal: the model answers in Markdown whatever
// the prompt says, so the chat shows it instead of the asterisks. Rendered
// line by line while streaming, and only when stdout is a terminal — pipes,
// files, --json and -q get the raw text.

import Foundation

enum Markdown {
    /// Streaming state: inside a ``` block, lines are dimmed as code.
    struct State { var inCode = false }

    /// Pure — unit-tested. One source line → one styled line (ANSI).
    static func render(_ line: String, state: inout State) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            state.inCode.toggle()
            let label = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return Style.dim.apply(state.inCode ? (label.isEmpty ? "┌ code" : "┌ \(label)") : "└")
        }
        if state.inCode { return Style.dim.apply("│ ") + Style.code.apply(line) }

        // Headings: bold, without the hashes.
        if let m = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
            return Style.bold.apply(inline(String(m.output.2)))
        }
        // Bullets: a real bullet, same indent.
        if let m = line.firstMatch(of: /^(\s*)[-*]\s+(.*)$/) {
            return String(m.output.1) + "• " + inline(String(m.output.2))
        }
        // Numbered lists and plain lines: inline styles only.
        return inline(line)
    }

    /// `**bold**`, `` `code` `` (and `*emphasis*` between spaces; underscores
    /// are left alone — snake_case is everywhere in code talk).
    static func inline(_ text: String) -> String {
        var out = text
        out = out.replacing(/`([^`]+)`/) { Style.code.apply(String($0.output.1)) }
        out = out.replacing(/\*\*([^*]+)\*\*/) { Style.bold.apply(String($0.output.1)) }
        // Emphasis only when the stars sit at word edges: "2 * 3" and "a*b" stay.
        out = out.replacing(/(^|\s)\*([^*\s][^*]*?)\*(?=$|\s|[.,;:!?)])/) { String($0.output.1) + Style.italic.apply(String($0.output.2)) }
        return out
    }

    /// Feeds streamed chunks and emits rendered text: whole lines as they
    /// complete, the rest at `finish()`.
    struct Renderer {
        private var buffer = ""
        private var state = State()

        mutating func push(_ chunk: String) -> String {
            buffer += chunk
            var out = ""
            while let nl = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<nl])
                buffer = String(buffer[buffer.index(after: nl)...])
                out += Markdown.render(line, state: &state) + "\n"
            }
            return out
        }

        mutating func finish() -> String {
            guard !buffer.isEmpty else { return "" }
            defer { buffer = "" }
            return Markdown.render(buffer, state: &state)
        }
    }
}
