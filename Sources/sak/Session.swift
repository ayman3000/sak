// One sak session: the agent, its tools, and everything a request needs.
// Switching provider or model builds a new agent and carries the conversation over.

import Foundation
import SwiftAgentKit
import SwiftAgentKitTools
import LLMProviderKit

struct SessionOptions {
    var autoApprove = false
    var readOnly = false
    var maxTurns = 30
    var console = Console()
}

/// Counters for one request and for the whole session. Written from the
/// agent's event callbacks, so it's lock-protected.
final class Stats: @unchecked Sendable {
    struct Totals { var requests = 0, inputTokens = 0, outputTokens = 0, cachedTokens = 0, toolCalls = 0 }
    private let lock = NSLock()
    private var _session = Totals()
    private var _lastSummary: AgentRunSummary?
    private var _deniedTools: [String] = []
    private var _toolsThisRequest: [String] = []
    private var _streamEndedWithNewline = true

    var session: Totals { lock.withLock { _session } }
    var lastSummary: AgentRunSummary? { lock.withLock { _lastSummary } }
    var deniedTools: [String] { lock.withLock { _deniedTools } }
    /// The tools this request called, in order (for the journal's kind).
    var toolsThisRequest: [String] { lock.withLock { _toolsThisRequest } }
    /// Whether the last streamed text ended a line — a prompt or progress
    /// line printed next must not run on from the model's sentence.
    var streamEndedWithNewline: Bool { lock.withLock { _streamEndedWithNewline } }
    func streamed(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        lock.withLock { _streamEndedWithNewline = chunk.hasSuffix("\n") }
    }

    func beginRequest() {
        lock.withLock { _session.requests += 1; _lastSummary = nil; _deniedTools = []; _toolsThisRequest = [] }
    }
    func add(_ usage: AgentTokenUsage?) {
        guard let usage else { return }
        lock.withLock {
            _session.inputTokens += usage.promptTokens ?? 0
            _session.outputTokens += usage.completionTokens ?? 0
            _session.cachedTokens += usage.cachedTokens ?? 0
        }
    }
    func toolCalled(_ name: String) { lock.withLock { _session.toolCalls += 1; _toolsThisRequest.append(name) } }
    func finished(_ summary: AgentRunSummary) { lock.withLock { _lastSummary = summary } }
    func denied(_ tool: String) {
        lock.withLock { if !_deniedTools.contains(tool) { _deniedTools.append(tool) } }
    }
}

/// Says when a tool call is taking long: after 5 s, then every 10 s, a dim
/// "… name still running (15 s)" — silence must never look like a hang
/// (a page that took a minute to load, 2026-11-09).
final class ToolWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var timers: [String: Task<Void, Never>] = [:]

    func started(_ call: AgentToolCall, console: Console) {
        let name = call.name
        let task = Task.detached {
            try? await Task.sleep(for: .seconds(5))
            var elapsed = 5
            while !Task.isCancelled {
                console.progress("  … \(name) still running (\(elapsed) s)", .dim)
                try? await Task.sleep(for: .seconds(10))
                elapsed += 10
            }
        }
        lock.withLock { timers[call.id] = task }
    }

    func finished(_ call: AgentToolCall) {
        lock.withLock { timers.removeValue(forKey: call.id) }?.cancel()
    }
}

/// Lets a callback reach the agent it belongs to (set right after the agent is built).
final class AgentRef: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _agent: Agent?
    var agent: Agent? {
        get { lock.withLock { _agent } }
        set { lock.withLock { _agent = newValue } }
    }
}

/// What the user said "always" to in this session: a tool, a whole MCP
/// server's tools, or everything. (An MCP server brings dozens of tools; one
/// answer per tool was one answer too many — 2026-11-09.)
final class Approvals: @unchecked Sendable {
    private let lock = NSLock()
    private var tools: Set<String> = []
    private var servers: Set<String> = []
    private var everything = false
    func isAllowed(tool: String, server: String?) -> Bool {
        lock.withLock { everything || tools.contains(tool) || (server.map { servers.contains($0) } ?? false) }
    }
    func allow(tool: String) { _ = lock.withLock { tools.insert(tool) } }
    func allow(server: String) { _ = lock.withLock { servers.insert(server) } }
    func allowEverything() { lock.withLock { everything = true } }
}

/// What one request produced.
struct RunOutcome {
    var response: String
    var error: Error?
    var summary: AgentRunSummary?
    var deniedTools: [String]
    var cancelled: Bool { (error as? AgentError) == .cancelled }

    /// Pure — unit-tested. The process exit code (see `sak --help`): 0 done,
    /// 1 error, 3 a tool needed approval and was denied, 4 turn limit,
    /// 130 stopped with Ctrl-C.
    var exitCode: Int32 {
        if !deniedTools.isEmpty { return 3 }
        if let error {
            switch error as? AgentError {
            case .cancelled?: return 130
            case .maxTurnsReached?, .maxTurnsReachedWithSummary?: return 4
            default: return 1
            }
        }
        return 0
    }
}

@MainActor
final class Session {
    let settings: Settings
    let cwd: URL
    var options: SessionOptions
    private(set) var choice: ModelChoice
    private(set) var agent: Agent
    private var provider: any LLMProvider
    private(set) var tools: [any AgentTool] = []
    let stats = Stats()
    let approvals = Approvals()
    let context: ProjectContext
    /// The model's context window in use, and where the number came from.
    private(set) var window: (tokens: Int, source: ModelWindows.Source) = (0, .assumed)
    /// MCP servers from mcp.json: their tools and a line or two about them.
    let mcp: MCPServers.Connected

    var console: Console { options.console }

    init(settings: Settings, cwd: URL, choice: ModelChoice, options: SessionOptions) async throws {
        self.settings = settings
        self.cwd = cwd
        self.choice = choice
        self.options = options
        self.context = ProjectContext(projectDirectory: cwd, settings: settings)
        self.mcp = await MCPServers.connect(projectDirectory: cwd, readOnly: options.readOnly, withNaseem: settings["SAK_NASEEM"] != "0")
        (self.agent, self.provider) = try await Self.makeAgent(settings: settings, cwd: cwd, choice: choice, options: options,
                                                               context: context, stats: stats, approvals: approvals, mcp: mcp)
        self.tools = await agent.registeredTools()
        await fitWindow()
    }

    /// Size the conversation to the model's real window (ModelWindows).
    private func fitWindow() async {
        let listed = await ModelWindows.listed(from: provider)
        let picked = ModelWindows.pick(model: choice.model, provider: choice.provider, listed: listed)
        agent.conversation.contextWindow = picked.window
        window = (picked.window, picked.source)
    }

    // MARK: - Switching

    /// Use a different provider/model. The conversation so far comes along.
    func switchTo(_ newChoice: ModelChoice) async throws {
        let history = agent.conversation.allMessages().filter { $0.role != .system }
        let (newAgent, newProvider) = try await Self.makeAgent(settings: settings, cwd: cwd, choice: newChoice, options: options,
                                                               context: context, stats: stats, approvals: approvals, mcp: mcp)
        newAgent.conversation.replaceNonSystemMessages(history)
        agent = newAgent
        provider = newProvider
        choice = newChoice
        tools = await agent.registeredTools()
        await fitWindow()
    }

    func setAutoApprove(_ on: Bool) async {
        options.autoApprove = on
        await agent.setAutonomousMode(on)
    }

    func clearConversation() { agent.conversation.replaceNonSystemMessages([]) }

    // MARK: - Running

    func run(_ prompt: String, streamTo stream: Bool = true, interrupts: Interrupts? = nil) async -> RunOutcome {
        stats.beginRequest()
        stats.streamed("\n")
        let agent = self.agent
        // Consume the stream in its own task so Ctrl-C can cancel it mid-answer:
        // the agent's flag alone is only checked between steps.
        let consumer = Task { () -> (String, Error?) in
            var response = ""
            // Markdown becomes bold/code/bullets on a terminal; raw everywhere else.
            var renderer = Console.stdoutColor ? Markdown.Renderer() : nil
            func emit(_ text: String) {
                guard !text.isEmpty else { return }
                FileHandle.standardOutput.write(Data(text.utf8)); stats.streamed(text)
            }
            do {
                for try await chunk in agent.runStreaming(prompt) {
                    response += chunk
                    if stream { emit(renderer?.push(chunk) ?? chunk) }
                }
                if stream, var r = renderer { emit(r.finish()); renderer = r }
                if Task.isCancelled { return (response, AgentError.cancelled) }
                return (response, nil)
            } catch {
                return (response, Task.isCancelled ? AgentError.cancelled : error)
            }
        }
        interrupts?.arm {
            agent.requestCancel()
            consumer.cancel()
        }
        defer { interrupts?.disarm() }
        let (response, failure) = await consumer.value
        if stream, !response.isEmpty, !response.hasSuffix("\n") {
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        // Naseem's journal gets a line for work done, never for a question.
        if !options.readOnly, let kind = ProjectContext.journalKind(toolsRun: stats.toolsThisRequest) {
            let result = failure.map { ($0 as? AgentError) == .cancelled ? "stopped" : "error: \($0)" }
                ?? Self.lastParagraph(response)
            context.appendJournal(request: prompt, outcome: result, kind: kind)
        }
        return RunOutcome(response: response, error: failure, summary: stats.lastSummary,
                          deniedTools: stats.deniedTools)
    }

    /// The answer's closing summary is usually its last paragraph.
    nonisolated static func lastParagraph(_ text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return paragraphs.last?.replacingOccurrences(of: "\n", with: " ") ?? "(no answer)"
    }

    // MARK: - Building the agent

    private static func makeAgent(settings: Settings, cwd: URL, choice: ModelChoice, options: SessionOptions,
                                  context: ProjectContext, stats: Stats, approvals: Approvals,
                                  mcp: MCPServers.Connected) async throws -> (Agent, any LLMProvider) {
        let provider = try choice.provider.makeProvider(model: choice.model, settings: settings)
        let tools = makeTools(settings: settings, cwd: cwd, readOnly: options.readOnly) + mcp.tools

        let agent = Agent(config: AgentConfig(
            provider: provider,
            model: choice.model,
            systemPrompt: systemPrompt(cwd: cwd, readOnly: options.readOnly, context: context),
            maxTurns: options.maxTurns,
            contextWindow: ModelWindows.fallback(choice.provider),   // fitted to the model right after (fitWindow)
            maxMessages: 400,
            tools: tools,
            autonomousMode: options.autoApprove
        ))

        if let skills = context.skillStore {
            try await agent.setSkillStore(skills)
        }

        let console = options.console
        let ref = AgentRef()
        ref.agent = agent
        let watch = ToolWatch()
        var callbacks = AgentCallbacks()
        let serverOf = mcp.serverOf
        callbacks.onToolConfirmation = { call, _ in
            let server = serverOf[call.name]
            if approvals.isAllowed(tool: call.name, server: server) { return true }
            guard isatty(STDIN_FILENO) != 0 else {
                // Nobody to ask (a script or CI): stop now rather than let the
                // model try other ways around the refusal. Exit code 3 says why.
                stats.denied(call.name)
                console.progress("  \(call.name) needs approval and there's no terminal to ask — stopping", .yellow)
                ref.agent?.requestCancel()
                return false
            }
            let scope = server.map { "  [s] all \($0) tools" } ?? ""
            let question = (stats.streamEndedWithNewline ? "" : "\n")
                + "? allow \(describe(call))\n  [y]es  [n]o  [a]lways for \(call.name)\(scope)  [A] everything this session › "
            FileHandle.standardError.write(Data((Console.stderrColor ? Style.yellow.apply(question) : question).utf8))
            let raw = Swift.readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
            let answer = raw == "A" ? "A" : raw.lowercased()
            stats.streamed("\n")   // the answer ended the line
            switch answer {
            case "y", "yes": return true
            case "a", "always": approvals.allow(tool: call.name); return true
            case "s", "server": if let server { approvals.allow(server: server) }; return true
            case "A", "all", "everything": approvals.allowEverything(); return true
            default: stats.denied(call.name); return false
            }
        }
        try await agent.setCallbacks(callbacks)

        agent.onEvent { event in
            switch event {
            case .llmCallCompleted(_, let response):
                stats.add(response.usage)
            case .toolExecutionStarted(let call):
                stats.toolCalled(call.name)
                if !stats.streamEndedWithNewline { console.progress("", .dim); stats.streamed("\n") }
                console.progress("→ \(describe(call, compact: true))", .cyan)
                watch.started(call, console: console)
            case .toolExecutionFinished(let call, let result):
                watch.finished(call)
                console.progress("  \(result.isError ? "✗" : "✓") \(oneLine(result.result))", result.isError ? .red : .dim)
            case .llmCallRetrying(_, let attempt, let error):
                console.progress("  retrying model call (\(attempt)): \(oneLine(error))", .yellow)
            case .loopDetected(let signature, _, _):
                console.progress("  loop detected: \(oneLine(signature))", .yellow)
            case .contextCompacted(let before, let after, _):
                console.progress("  context compacted: \(before) → \(after) tokens", .dim)
            case .finished(let summary):
                stats.finished(summary)
            default:
                break
            }
        }
        return (agent, provider)
    }

    static func makeTools(settings: Settings, cwd: URL, readOnly: Bool) -> [any AgentTool] {
        // File tools may only touch the folder sak was started in.
        let policy = FileToolPolicy(allowedRoots: [cwd])
        var tools: [any AgentTool] = [
            ListDirTool(policy: policy),
            SearchFilesTool(policy: policy),
            FileReadTool(policy: policy),
            FetchURLTool(),
        ]
        if !readOnly {
            tools += [
                FileWriteTool(policy: policy),
                EditFileTool(policy: policy),
                ShellTool(defaultWorkingDirectory: cwd),
            ]
        }
        if let key = settings["TAVILY_API_KEY"] {
            tools.append(TavilySearchTool(apiKey: key))
        }
        return tools
    }

    private static func systemPrompt(cwd: URL, readOnly: Bool, context: ProjectContext) -> String {
        var prompt = """
        You are sak, a coding agent working in a terminal on macOS, built on SwiftAgentKit.
        The project folder is \(cwd.path). Relative paths resolve there.
        Look before you change: list and read files first. Make focused edits.
        After changing code, build or test it with run_shell when that makes sense.
        Answer concisely; Markdown is fine (headings, bullets, code).
        Make the code pass the tests, never the tests pass the code: don't edit or delete a test you were asked to \
        make pass; adding a test is fine. If a test looks wrong, say so and stop.
        Finish with a short summary of what you did.
        """
        if readOnly {
            prompt += "\n\nYou are in READ-ONLY mode: you can read files and search, but not edit files or run commands. Report what you find and what you would change."
        }
        if let notes = context.promptSection() {
            prompt += "\n\n" + notes
        }
        return prompt
    }
}

/// `edit_file path=… old_text=… new_text=…` for the approval prompt; the
/// compact form (progress lines) shows an edit as its file and line counts,
/// a write as its file and size — the texts themselves made the lines
/// unreadable (2026-11-09).
func describe(_ call: AgentToolCall, compact: Bool = false) -> String {
    let p = call.parameters
    func str(_ k: String) -> String? { p[k].map { String(describing: $0.value) } }
    if compact, call.name == "edit_file", let path = str("path") {
        let old = str("old_text") ?? "", new = str("new_text") ?? ""
        return "edit_file \(path)  (\(old.split(separator: "\n", omittingEmptySubsequences: false).count) → \(new.split(separator: "\n", omittingEmptySubsequences: false).count) lines)"
    }
    if compact, call.name == "write_file", let path = str("path") {
        return "write_file \(path)  (\((str("content") ?? "").utf8.count) bytes)"
    }
    let args = p.sorted { $0.key < $1.key }
        .map { "\($0.key)=\(oneLine(String(describing: $0.value.value), max: compact ? 60 : 160))" }
        .joined(separator: " ")
    return "\(call.name) \(args)"
}
