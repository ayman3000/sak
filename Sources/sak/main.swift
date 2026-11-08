// sak — a terminal coding agent for Apple developers, built on SwiftAgentKit.
//
//   sak                          chat in the current folder (/help for commands)
//   sak "fix the failing test"   one request, then exit
//   swift test 2>&1 | sak "why does this fail?"     piped input
//   sak --read-only --json "review this repo"       for scripts and CI
//
// Settings (API keys, SAK_PROVIDER, SAK_MODEL) come from the environment,
// ./.env or ~/.config/sak/.env — see DotEnv.swift.

import Foundation
import SwiftAgentKit

let version = "0.2.0-alpha"

// MARK: - Arguments

struct Arguments {
    var provider: ProviderKind?
    var model: String?
    var autoApprove = false
    var readOnly = false
    var maxTurns = 30
    var json = false
    var quiet = false
    var continueLast = false
    var promptWords: [String] = []
}

func usage() -> String {
    """
    sak \(version) — a coding agent for your terminal, built on SwiftAgentKit

    usage: sak [options] [prompt…]

      With no prompt, starts a chat (type /help inside). With a prompt, or with
      input piped in, runs one request and exits.

    options:
      -P, --provider NAME   ollama, anthropic, openai, gemini, openrouter
      -m, --model NAME      model id (e.g. claude-opus-5-5, kimi-k2.6:cloud)
      -y, --yes             approve edits and shell commands without asking
      -r, --read-only       no edit or shell tools — safe for CI and reviews
      -c, --continue        continue this folder's last chat
      --json                print one JSON result (for scripts); progress → stderr
      -q, --quiet           no progress lines, only the answer
      --turns N             max agent turns per request (default 30)
      -v, --version         print the version
      -h, --help            this help

    exit codes:
      0 done · 1 error · 2 bad usage or missing key · 3 a tool needed approval
      and was denied · 4 hit the turn limit · 130 stopped with Ctrl-C

    settings: ~/.config/sak/.env (or ./.env) — ANTHROPIC_API_KEY, OPENAI_API_KEY,
    GEMINI_API_KEY, OPENROUTER_API_KEY, TAVILY_API_KEY, SAK_PROVIDER, SAK_MODEL, OLLAMA_HOST
    """
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    Console().error("sak: \(message)")
    exit(code)
}

func parseArguments() -> Arguments {
    var parsed = Arguments()
    var args = CommandLine.arguments.dropFirst()
    while let arg = args.popFirst() {
        switch arg {
        case "-P", "--provider":
            guard let value = args.popFirst() else { fail("--provider needs a name") }
            guard let kind = ProviderKind(alias: value) else {
                fail("unknown provider '\(value)' — use one of: \(ProviderKind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            parsed.provider = kind
        case "-m", "--model":
            guard let value = args.popFirst() else { fail("--model needs a name") }
            parsed.model = value
        case "-y", "--yes": parsed.autoApprove = true
        case "-r", "--read-only": parsed.readOnly = true
        case "-c", "--continue": parsed.continueLast = true
        case "--json": parsed.json = true
        case "-q", "--quiet": parsed.quiet = true
        case "--turns":
            guard let value = args.popFirst(), let n = Int(value), n > 0 else { fail("--turns needs a positive number") }
            parsed.maxTurns = n
        case "-v", "--version":
            print("sak \(version)")
            exit(0)
        case "-h", "--help":
            print(usage())
            exit(0)
        case "--":
            parsed.promptWords += args
            args = []
        default:
            if arg.hasPrefix("-"), arg.count > 1, parsed.promptWords.isEmpty {
                fail("unknown option \(arg) (see sak --help)")
            }
            parsed.promptWords.append(arg)
        }
    }
    return parsed
}

/// Flags win, then the last /model choice, then SAK_PROVIDER / SAK_MODEL, then the defaults.
func resolveChoice(_ args: Arguments, settings: Settings) -> ModelChoice {
    let saved = ModelChoice.saved()
    let configured = settings["SAK_PROVIDER"].flatMap(ProviderKind.init(alias:))
    let provider = args.provider ?? saved?.provider ?? configured ?? .ollama
    let model = args.model
        ?? (saved?.provider == provider ? saved?.model : nil)
        ?? (configured == provider || (configured == nil && provider == .ollama) ? settings["SAK_MODEL"] : nil)
        ?? provider.defaultModel
    return ModelChoice(provider: provider, model: model)
}

// MARK: - Start

let args = parseArguments()
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let settings = Settings(projectDirectory: cwd)
let choice = resolveChoice(args, settings: settings)

// Piped input becomes part of the request: `git diff | sak "review this"`.
let stdinIsTTY = isatty(STDIN_FILENO) != 0
var piped = ""
if !stdinIsTTY {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    piped = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
let oneShot = !args.promptWords.isEmpty || !piped.isEmpty || args.json || !stdinIsTTY

var console = Console()
console.progressToStderr = oneShot
console.quiet = args.quiet

let options = SessionOptions(autoApprove: args.autoApprove, readOnly: args.readOnly,
                             maxTurns: args.maxTurns, console: console)
let session: Session
do {
    session = try await Session(settings: settings, cwd: cwd, choice: choice, options: options)
} catch {
    fail("\(error)")
}

if args.continueLast {
    let name = SavedSessions.defaultName(for: cwd)
    if await SavedSessions.load(into: session.agent, name: name) {
        console.progress("(continuing this folder's last chat)")
    } else if !oneShot {
        console.progress("(no earlier chat in this folder — starting fresh)")
    }
}

let interrupts = Interrupts()
interrupts.install(console: console)

// MARK: - One request (prompt, pipe, or --json)

if oneShot {
    var prompt = args.promptWords.joined(separator: " ")
    if !piped.isEmpty {
        prompt = prompt.isEmpty ? piped : "\(prompt)\n\n<input>\n\(piped)\n</input>"
    }
    if prompt.isEmpty { fail("nothing to do — give a prompt or pipe input in (see sak --help)") }

    let outcome = await session.run(prompt, streamTo: !args.json, interrupts: interrupts)
    let code = exitCode(for: outcome)
    if args.json {
        printJSON(outcome, code: code, session: session)
    } else if code == 3 {
        console.error("sak: needed approval for \(outcome.deniedTools.joined(separator: ", ")) — rerun with -y to allow it, or use --read-only")
    } else if let error = outcome.error, !outcome.cancelled {
        console.error("sak: \(describe(error))")
    }
    exit(code)
}

func exitCode(for outcome: RunOutcome) -> Int32 {
    if !outcome.deniedTools.isEmpty { return 3 }
    if let error = outcome.error {
        switch error as? AgentError {
        case .cancelled?: return 130
        case .maxTurnsReached?, .maxTurnsReachedWithSummary?: return 4
        default: return 1
        }
    }
    return 0
}

func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
}

@MainActor
func printJSON(_ outcome: RunOutcome, code: Int32, session: Session) {
    let totals = session.stats.session
    var object: [String: Any] = [
        "ok": code == 0,
        "exit_code": Int(code),
        "provider": session.choice.provider.rawValue,
        "model": session.choice.model,
        "response": outcome.response,
        "tool_calls": totals.toolCalls,
        "denied_tools": outcome.deniedTools,
        "usage": ["input_tokens": totals.inputTokens, "output_tokens": totals.outputTokens,
                  "cached_tokens": totals.cachedTokens],
    ]
    if let summary = outcome.summary {
        object["turns"] = summary.totalTurns
        object["tool_errors"] = summary.toolErrors
        object["elapsed_seconds"] = NSDecimalNumber(string: String(format: "%.2f", summary.elapsed))
    }
    if let error = outcome.error { object["error"] = describe(error) }
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    print(String(decoding: data, as: UTF8.self))
}

// MARK: - Chat

@MainActor
func banner() {
    let c = session.choice
    var flags: [String] = []
    if session.options.autoApprove { flags.append("auto-approve") }
    if session.options.readOnly { flags.append("read-only") }
    if session.tools.contains(where: { $0.name == "web_search" }) { flags.append("web search") }
    console.out(console.styled("sak \(version)", .bold) + console.styled("  ·  \(c.model) (\(c.provider.displayName))", .magenta))
    console.out(console.styled("\(cwd.path)\(flags.isEmpty ? "" : "  ·  " + flags.joined(separator: " · "))", .dim))
    if !settings.loadedFiles.isEmpty {
        console.out(console.styled("settings: \(settings.loadedFiles.joined(separator: ", "))", .dim))
    }
    if let notes = session.context.summaryLine {
        console.out(console.styled(notes, .dim))
    }
    console.out(console.styled("/help for commands · Ctrl-C stops a request · Ctrl-D quits", .dim))
}

banner()
LineEditor.start()
let commands = Commands(session: session)

chat: while true {
    console.out("")
    guard var line = LineEditor.readLine(prompt: "› ") else { break }
    // A trailing backslash continues the request on the next line.
    while line.hasSuffix("\\") {
        line.removeLast()
        guard let more = LineEditor.readLine(prompt: "… ") else { break }
        line += "\n" + more
    }
    let input = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if input.isEmpty { continue }

    if input.hasPrefix("/") {
        if await commands.handle(input) == .exit { break chat }
        continue
    }

    let outcome = await session.run(input, interrupts: interrupts)
    if let error = outcome.error {
        console.out(outcome.cancelled
            ? console.styled("(stopped)", .yellow)
            : console.styled("error: \(describe(error))", .red))
    }
    try? await SavedSessions.save(session.agent, name: SavedSessions.defaultName(for: cwd))
}
console.out(console.styled("bye — `sak -c` picks this chat up again", .dim))
