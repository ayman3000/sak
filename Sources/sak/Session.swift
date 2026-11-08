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

    var session: Totals { lock.withLock { _session } }
    var lastSummary: AgentRunSummary? { lock.withLock { _lastSummary } }
    var deniedTools: [String] { lock.withLock { _deniedTools } }

    func beginRequest() { lock.withLock { _session.requests += 1; _lastSummary = nil; _deniedTools = [] } }
    func add(_ usage: AgentTokenUsage?) {
        guard let usage else { return }
        lock.withLock {
            _session.inputTokens += usage.promptTokens ?? 0
            _session.outputTokens += usage.completionTokens ?? 0
            _session.cachedTokens += usage.cachedTokens ?? 0
        }
    }
    func toolCalled() { lock.withLock { _session.toolCalls += 1 } }
    func finished(_ summary: AgentRunSummary) { lock.withLock { _lastSummary = summary } }
    func denied(_ tool: String) {
        lock.withLock { if !_deniedTools.contains(tool) { _deniedTools.append(tool) } }
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

/// Tools the user said "always" to in this session.
final class Approvals: @unchecked Sendable {
    private let lock = NSLock()
    private var always: Set<String> = []
    func isAlways(_ tool: String) -> Bool { lock.withLock { always.contains(tool) } }
    func allowAlways(_ tool: String) { _ = lock.withLock { always.insert(tool) } }
}

/// What one request produced.
struct RunOutcome {
    var response: String
    var error: Error?
    var summary: AgentRunSummary?
    var deniedTools: [String]
    var cancelled: Bool { (error as? AgentError) == .cancelled }
}

@MainActor
final class Session {
    let settings: Settings
    let cwd: URL
    var options: SessionOptions
    private(set) var choice: ModelChoice
    private(set) var agent: Agent
    private(set) var tools: [any AgentTool] = []
    let stats = Stats()
    let approvals = Approvals()
    let context: ProjectContext

    var console: Console { options.console }

    init(settings: Settings, cwd: URL, choice: ModelChoice, options: SessionOptions) async throws {
        self.settings = settings
        self.cwd = cwd
        self.choice = choice
        self.options = options
        self.context = ProjectContext(projectDirectory: cwd, settings: settings)
        self.agent = try await Self.makeAgent(settings: settings, cwd: cwd, choice: choice, options: options,
                                              context: context, stats: stats, approvals: approvals)
        self.tools = await agent.registeredTools()
    }

    // MARK: - Switching

    /// Use a different provider/model. The conversation so far comes along.
    func switchTo(_ newChoice: ModelChoice) async throws {
        let history = agent.conversation.allMessages().filter { $0.role != .system }
        let newAgent = try await Self.makeAgent(settings: settings, cwd: cwd, choice: newChoice, options: options,
                                                context: context, stats: stats, approvals: approvals)
        newAgent.conversation.replaceNonSystemMessages(history)
        agent = newAgent
        choice = newChoice
        tools = await agent.registeredTools()
    }

    func setAutoApprove(_ on: Bool) async {
        options.autoApprove = on
        await agent.setAutonomousMode(on)
    }

    func clearConversation() { agent.conversation.replaceNonSystemMessages([]) }

    // MARK: - Running

    func run(_ prompt: String, streamTo stream: Bool = true, interrupts: Interrupts? = nil) async -> RunOutcome {
        stats.beginRequest()
        let agent = self.agent
        // Consume the stream in its own task so Ctrl-C can cancel it mid-answer:
        // the agent's flag alone is only checked between steps.
        let consumer = Task { () -> (String, Error?) in
            var response = ""
            do {
                for try await chunk in agent.runStreaming(prompt) {
                    response += chunk
                    if stream { FileHandle.standardOutput.write(Data(chunk.utf8)) }
                }
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
        if !options.readOnly {
            let result = failure.map { ($0 as? AgentError) == .cancelled ? "stopped" : "error: \($0)" }
                ?? Self.lastParagraph(response)
            context.appendJournal(request: prompt, outcome: result)
        }
        return RunOutcome(response: response, error: failure, summary: stats.lastSummary,
                          deniedTools: stats.deniedTools)
    }

    /// The answer's closing summary is usually its last paragraph.
    static func lastParagraph(_ text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return paragraphs.last?.replacingOccurrences(of: "\n", with: " ") ?? "(no answer)"
    }

    // MARK: - Building the agent

    private static func makeAgent(settings: Settings, cwd: URL, choice: ModelChoice, options: SessionOptions,
                                  context: ProjectContext, stats: Stats, approvals: Approvals) async throws -> Agent {
        let provider = try choice.provider.makeProvider(model: choice.model, settings: settings)
        let tools = makeTools(settings: settings, cwd: cwd, readOnly: options.readOnly)

        let agent = Agent(config: AgentConfig(
            provider: provider,
            model: choice.model,
            systemPrompt: systemPrompt(cwd: cwd, readOnly: options.readOnly, context: context),
            maxTurns: options.maxTurns,
            contextWindow: 128_000,
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
        var callbacks = AgentCallbacks()
        callbacks.onToolConfirmation = { call, _ in
            if approvals.isAlways(call.name) { return true }
            guard isatty(STDIN_FILENO) != 0 else {
                // Nobody to ask (a script or CI): stop now rather than let the
                // model try other ways around the refusal. Exit code 3 says why.
                stats.denied(call.name)
                console.progress("  \(call.name) needs approval and there's no terminal to ask — stopping", .yellow)
                ref.agent?.requestCancel()
                return false
            }
            let question = "? allow \(describe(call))\n  [y]es  [n]o  [a]lways for \(call.name) this session › "
            FileHandle.standardError.write(Data((Console.stderrColor ? Style.yellow.apply(question) : question).utf8))
            let answer = Swift.readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            switch answer {
            case "y", "yes": return true
            case "a", "always": approvals.allowAlways(call.name); return true
            default: stats.denied(call.name); return false
            }
        }
        try await agent.setCallbacks(callbacks)

        agent.onEvent { event in
            switch event {
            case .llmCallCompleted(_, let response):
                stats.add(response.usage)
            case .toolExecutionStarted(let call):
                stats.toolCalled()
                console.progress("→ \(describe(call))", .cyan)
            case .toolExecutionFinished(_, let result):
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
        return agent
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
        Answer in plain text suited to a terminal. Finish with a short summary of what you did.
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

func describe(_ call: AgentToolCall) -> String {
    let args = call.parameters
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\(oneLine(String(describing: $0.value.value), max: 60))" }
        .joined(separator: " ")
    return "\(call.name) \(args)"
}
