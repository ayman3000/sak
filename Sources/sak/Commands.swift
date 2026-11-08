// Slash commands for the interactive chat: /model, /provider, /tools, …

import Foundation
import SwiftAgentKit
import LLMProviderKit

enum CommandResult { case handled, exit }

@MainActor
struct Commands {
    let session: Session
    var console: Console { session.console }

    static let help: [(String, String)] = [
        ("/model [name|number]", "show or switch the model (no name: pick from a list)"),
        ("/provider [name] [model]", "switch provider: ollama, anthropic, openai, gemini, openrouter"),
        ("/providers", "list providers and which ones have a key"),
        ("/tools", "list the tools the agent can use"),
        ("/skills", "list the skills the agent can load"),
        ("/notes", "show the project notes sak loaded"),
        ("/yes", "toggle auto-approve for edits and shell commands"),
        ("/usage", "tokens and tool calls so far"),
        ("/save [name]", "save this conversation"),
        ("/resume [name]", "load a saved conversation (no name: list them)"),
        ("/clear", "start a fresh conversation"),
        ("/exit", "quit (or Ctrl-D)"),
    ]

    func handle(_ line: String) async -> CommandResult {
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts.first?.lowercased() ?? ""
        let args = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        switch name {
        case "help", "?": showHelp()
        case "model", "m": await model(args)
        case "models": await listModels()
        case "provider", "p": await provider(args)
        case "providers": listProviders()
        case "tools": listTools()
        case "skills": await listSkills()
        case "notes": showNotes()
        case "yes", "auto": await toggleAutoApprove()
        case "usage", "cost": await showUsage()
        case "save": await save(args)
        case "resume", "load": await resume(args)
        case "clear", "reset", "new":
            session.clearConversation()
            console.out(console.styled("(conversation cleared)", .dim))
        case "exit", "quit", "q": return .exit
        default:
            console.out(console.styled("Unknown command /\(name). Type /help.", .yellow))
        }
        return .handled
    }

    // MARK: - Help

    private func showHelp() {
        for (command, text) in Self.help {
            let padded = command.padding(toLength: 26, withPad: " ", startingAt: 0)
            console.out("  \(console.styled(padded, .cyan)) \(text)")
        }
        console.out(console.styled("""

          Ctrl-C stops a running request · ↑/↓ history · Ctrl-R search history
          Multi-line: end a line with \\ to continue it
        """, .dim))
    }

    // MARK: - Model and provider

    private func model(_ args: String) async {
        if args.isEmpty {
            console.out("Model: \(console.styled(session.choice.model, .bold)) on \(session.choice.provider.displayName)")
            await pickModel()
            return
        }
        await switchTo(ModelChoice(provider: session.choice.provider, model: args))
    }

    /// Lists the provider's models and lets the user pick one by number.
    private func pickModel() async {
        guard let models = await fetchModels() else { return }
        if models.isEmpty { return }
        console.out(console.styled("Pick a number, or Enter to keep the current model:", .dim))
        guard let answer = LineEditor.readLine(prompt: "model › ")?.trimmingCharacters(in: .whitespaces),
              !answer.isEmpty else { return }
        if let n = Int(answer), (1...models.count).contains(n) {
            await switchTo(ModelChoice(provider: session.choice.provider, model: models[n - 1].id))
        } else {
            await switchTo(ModelChoice(provider: session.choice.provider, model: answer))
        }
    }

    private func listModels() async { _ = await fetchModels() }

    /// Prints a numbered list of the current provider's models; nil if listing failed.
    private func fetchModels() async -> [LLMModelInfo]? {
        let kind = session.choice.provider
        do {
            let provider = try kind.makeProvider(model: session.choice.model, settings: session.settings)
            // Only models that can chat: no embedding, image or speech models.
            var models = try await provider.availableModels().filter { info in
                !info.capabilities.contains(.embeddings) && !info.categories.contains(.embedding)
                    && !info.id.localizedCaseInsensitiveContains("embed")
                    && !info.capabilities.contains(.imageGeneration) && !info.capabilities.contains(.textToSpeech)
            }
            models.sort { $0.id < $1.id }
            if models.count > 60 {
                // OpenRouter lists hundreds; keep the list readable.
                console.out(console.styled("(\(models.count) models — showing the first 60; type any id to use it)", .dim))
                models = Array(models.prefix(60))
            }
            for (i, info) in models.enumerated() {
                let marker = info.id == session.choice.model ? console.styled(" ← current", .green) : ""
                let window = info.contextWindow.map { console.styled("  \($0 / 1000)k", .dim) } ?? ""
                console.out("  \(String(i + 1).leftPad(3)). \(info.id)\(window)\(marker)")
            }
            return models
        } catch {
            console.out(console.styled("Couldn't list \(kind.displayName) models: \(error)", .yellow))
            console.out(console.styled("You can still switch by name: /model <name>", .dim))
            return nil
        }
    }

    private func provider(_ args: String) async {
        let words = args.split(separator: " ").map(String.init)
        guard let first = words.first else {
            listProviders()
            return
        }
        guard let kind = ProviderKind(alias: first) else {
            console.out(console.styled("Unknown provider '\(first)'. Try: \(ProviderKind.allCases.map(\.rawValue).joined(separator: ", "))", .yellow))
            return
        }
        let model = words.count > 1 ? words[1] : kind.defaultModel
        await switchTo(ModelChoice(provider: kind, model: model))
    }

    private func listProviders() {
        for kind in ProviderKind.allCases {
            let current = kind == session.choice.provider ? console.styled(" ← current", .green) : ""
            let status = kind.unavailableReason(in: session.settings).map { console.styled("  (\($0))", .dim) }
                ?? console.styled("  ready", .green)
            console.out("  \(kind.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0))\(status)\(current)")
        }
    }

    private func switchTo(_ choice: ModelChoice) async {
        do {
            try await session.switchTo(choice)
            choice.save()
            console.out("Now using \(console.styled(choice.model, .bold)) on \(choice.provider.displayName).")
        } catch {
            console.out(console.styled("Can't switch: \(error)", .yellow))
        }
    }

    // MARK: - Tools, skills, notes

    private func listTools() {
        for tool in session.tools.sorted(by: { $0.name < $1.name }) {
            let gate = tool.requiresConfirmation ? console.styled(" (asks)", .yellow) : ""
            let first = tool.description.split(separator: ".").first.map(String.init) ?? tool.description
            console.out("  \(console.styled(tool.name, .cyan))\(gate)  \(console.styled(oneLine(first, max: 80), .dim))")
        }
        if session.options.readOnly {
            console.out(console.styled("  read-only mode: no edit or shell tools", .dim))
        }
        if session.settings["TAVILY_API_KEY"] == nil {
            console.out(console.styled("  add TAVILY_API_KEY to ~/.config/sak/.env for web_search", .dim))
        }
    }

    private func listSkills() async {
        guard let store = session.context.skillStore,
              let skills = try? await store.loadAll(), !skills.isEmpty else {
            console.out(console.styled("No skills found.", .dim))
            return
        }
        for skill in skills {
            console.out("  \(console.styled(skill.name, .cyan))  \(console.styled(oneLine(skill.description, max: 90), .dim))")
        }
    }

    private func showNotes() {
        guard let section = session.context.promptSection() else {
            console.out(console.styled("No project notes (no naseem/ folder here).", .dim))
            return
        }
        console.out(section)
    }

    // MARK: - Approval, usage

    private func toggleAutoApprove() async {
        let on = !session.options.autoApprove
        await session.setAutoApprove(on)
        console.out(on
            ? console.styled("Auto-approve ON: edits and shell commands run without asking.", .yellow)
            : "Auto-approve off: sak asks before edits and shell commands.")
    }

    private func showUsage() async {
        let t = session.stats.session
        let context = await session.agent.lastPromptTokens
        console.out("""
          model          \(session.choice.model) (\(session.choice.provider.displayName))
          requests       \(t.requests)
          input tokens   \(t.inputTokens.grouped)\(t.cachedTokens > 0 ? " (\(t.cachedTokens.grouped) from cache)" : "")
          output tokens  \(t.outputTokens.grouped)
          tool calls     \(t.toolCalls)
          context        ~\(context.grouped) tokens in the last request
        """)
    }

    // MARK: - Sessions

    private func save(_ args: String) async {
        let name = args.isEmpty ? SavedSessions.defaultName(for: session.cwd) : args
        do {
            try await SavedSessions.save(session.agent, name: name)
            console.out("Saved as \(console.styled(name, .bold)). Resume with /resume \(name) or sak -c.")
        } catch {
            console.out(console.styled("Couldn't save: \(error)", .yellow))
        }
    }

    private func resume(_ args: String) async {
        if args.isEmpty {
            let names = await SavedSessions.list()
            if names.isEmpty { console.out(console.styled("No saved conversations.", .dim)) }
            for name in names { console.out("  \(name)") }
            return
        }
        if await SavedSessions.load(into: session.agent, name: args) {
            let count = session.agent.conversation.allMessages().filter { $0.role != .system }.count
            console.out("Resumed \(console.styled(args, .bold)) (\(count) messages).")
        } else {
            console.out(console.styled("No saved conversation named \(args).", .yellow))
        }
    }
}

// MARK: - Saved conversations

enum SavedSessions {
    static let store = FileSessionStore(
        directory: Settings.globalFile.deletingLastPathComponent().appendingPathComponent("sessions"))

    /// One automatic slot per project folder, used by `sak -c`.
    static func defaultName(for folder: URL) -> String {
        let base = folder.lastPathComponent.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let hash = folder.path.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        return "\(base.isEmpty ? "root" : base)-\(String(hash, radix: 16))"
    }

    static func save(_ agent: Agent, name: String) async throws {
        try await agent.saveSession(store: store, sessionId: name)
    }

    static func load(into agent: Agent, name: String) async -> Bool {
        (try? await agent.loadSession(store: store, sessionId: name)) ?? false
    }

    static func list() async -> [String] {
        ((try? await store.listSessions()) ?? []).sorted()
    }
}

extension Int {
    var grouped: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: self)) ?? String(self)
    }
}

extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
