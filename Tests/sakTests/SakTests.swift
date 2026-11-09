import Testing
import Foundation
import LLMProviderKit
import SwiftAgentKit
@testable import sak

// The pure parts of sak. The agent itself is SwiftAgentKit's and tested there.

struct SettingsTests {
    @Test func dotEnvLinesAreReadLikePythonDotenv() {
        let parsed = Settings.parse("""
        # comment
        A=1
        export B = two
        C="quoted # not a comment"
        D='single'
        E=value # trailing comment
        BAD LINE
        =nokey
        """)
        #expect(parsed == ["A": "1", "B": "two", "C": "quoted # not a comment", "D": "single", "E": "value"])
    }
}

struct ProjectContextTests {
    @Test func theRoadmapKeepsOnlyOpenItems() {
        let roadmap = "# Roadmap\n## Next\n- a\n## Done\n- b\n## Later\n- c\n"
        #expect(ProjectContext.openItems(roadmap) == "# Roadmap\n## Next\n- a\n## Later\n- c")
        #expect(ProjectContext.openItems("## Done\n- all") == "(everything on the roadmap is done)")
    }

    @Test func clipKeepsTheFirstLineWithinTheLimit() {
        #expect(ProjectContext.clip("first line\nsecond", 120) == "first line")
        #expect(ProjectContext.clip(String(repeating: "x", count: 10), 4) == "xxxx…")
    }

    /// Naseem reads `- date [kind] — …` (ProjectNotes.swift); anything else is
    /// "an older line" to its charts and keeper.
    @Test func journalLinesAreInNaseemsFormat() {
        let at = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .current, year: 2026, month: 11, day: 8, hour: 18, minute: 40))!
        let line = ProjectContext.journalLine(request: "add a --verbose flag", outcome: "Added it; tests pass.", kind: .build, now: at)
        #expect(line == "- 2026-11-08 18:40 [build] — sak: asked add a --verbose flag → Added it; tests pass.")
        let tag = try! Regex(#"^(- \d{4}-\d{2}-\d{2}(?: \d{2}:\d{2})?) \[([^\]]*)\]"#)   // Naseem's own pattern
        #expect(line.firstMatch(of: tag)?.output[2].substring == "build")
    }

    @Test func onlyWorkThatChangedSomethingIsJournaled() {
        #expect(ProjectContext.journalKind(toolsRun: ["read_file", "search_files"]) == nil, "a question")
        #expect(ProjectContext.journalKind(toolsRun: []) == nil)
        #expect(ProjectContext.journalKind(toolsRun: ["read_file", "edit_file"]) == .build)
        #expect(ProjectContext.journalKind(toolsRun: ["run_shell"]) == .build)
    }

    /// APFS compares names case-insensitively: a `Naseem/` source folder must
    /// not pass for the `naseem/` notes folder.
    @Test func theNotesFolderIsMatchedByExactName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sak-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Naseem"), withIntermediateDirectories: true)
        #expect(ProjectContext.notesFolder(in: root) == nil)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Naseem"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("naseem"), withIntermediateDirectories: true)
        #expect(ProjectContext.notesFolder(in: root)?.lastPathComponent == "naseem")
    }

    @Test func sakSkillsWinOverNaseemsAndNaseemsAreReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sak-skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = root.appendingPathComponent("mine"), theirs = root.appendingPathComponent("theirs")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        let store = SharedSkillStore(own: mine, readOnly: theirs)
        try await FileAgentSkillStore(directory: theirs).save(AgentSkill(name: "shared", description: "theirs", instructions: "N"))
        try await FileAgentSkillStore(directory: theirs).save(AgentSkill(name: "only-naseem", description: "theirs", instructions: "N"))
        try await store.save(AgentSkill(name: "shared", description: "mine", instructions: "S"))
        let all = try await store.loadAll()
        #expect(all.count == 2)
        #expect(all.first { $0.name == "shared" }?.description == "mine")
        await #expect(throws: SakError.self) { try await store.delete(name: "only-naseem") }
    }
}

struct MarkdownTests {
    let B = "\u{1B}[1m", C = "\u{1B}[36m", D = "\u{1B}[2m", R = "\u{1B}[0m"

    @Test func inlineStylesAndHeadingsAndBullets() {
        var st = Markdown.State()
        #expect(Markdown.render("## Fix", state: &st) == "\(B)Fix\(R)")
        #expect(Markdown.render("- use `HH:mm` **now**", state: &st) == "• use \(C)HH:mm\(R) \(B)now\(R)")
        #expect(Markdown.render("snake_case stays, 2 * 3 stays", state: &st) == "snake_case stays, 2 * 3 stays")
        #expect(Markdown.render("1. first", state: &st) == "1. first")
    }

    @Test func fencedCodeIsDimmedUntilTheClosingFence() {
        var st = Markdown.State()
        #expect(Markdown.render("```swift", state: &st) == "\(D)┌ swift\(R)")
        #expect(st.inCode)
        #expect(Markdown.render("let **x** = 1", state: &st) == "\(D)│ \(R)\(C)let **x** = 1\(R)", "no inline styling inside code")
        #expect(Markdown.render("```", state: &st) == "\(D)└\(R)")
        #expect(!st.inCode)
    }

    @Test func theRendererEmitsWholeLinesAndFlushesTheRest() {
        var r = Markdown.Renderer()
        #expect(r.push("**bo") == "")
        #expect(r.push("ld**\nnext") == "\(B)bold\(R)\n")
        #expect(r.finish() == "next")
        #expect(r.finish() == "")
    }
}

struct MCPServersTests {
    @Test func claudeStyleFilesAreRead() throws {
        let json = """
        { "mcpServers": {
            "chrome-devtools": { "command": "npx", "args": ["-y", "chrome-devtools-mcp@latest"], "env": { "A": "1" } },
            "docs": { "url": "https://example.com/mcp" },
            "off": { "command": "x", "disabled": true } } }
        """
        let servers = try MCPServers.parse(Data(json.utf8))
        #expect(servers.map(\.name) == ["chrome-devtools", "docs"], "sorted; disabled left out")
        #expect(servers[0].config == .stdio(command: "npx", args: ["-y", "chrome-devtools-mcp@latest"], env: ["A": "1"]))
        #expect(servers[1].config == .http(URL(string: "https://example.com/mcp")!))
    }
    /// Naseem's own list (settings.mcpServers, JSON): enabled stdio/http servers
    /// come along; sign-in servers are named, not started; a dash the keyboard
    /// "corrected" in a flag is put back.
    @Test func naseemsServersComeAlongExceptSignIns() {
        let json = """
        [ {"name": "chrome-devtools", "transport": "stdio", "command": "npx", "args": ["-y", "chrome-devtools-mcp@latest", "\u{2014}isolated"], "enabled": true, "signIn": false},
          {"name": "notion", "transport": "http", "endpoint": "https://mcp.notion.com/mcp", "enabled": true, "signIn": true},
          {"name": "files", "command": "npx", "args": ["x"], "enabled": false},
          {"name": "docs", "transport": "http", "endpoint": "https://example.com/mcp", "enabled": true} ]
        """
        let (servers, signIn) = MCPServers.parseNaseem(Data(json.utf8))
        #expect(servers.map(\.name) == ["chrome-devtools", "docs"])
        #expect(servers[0].config == .stdio(command: "npx", args: ["-y", "chrome-devtools-mcp@latest", "--isolated"], env: [:]))
        #expect(servers[0].source == "Naseem")
        #expect(signIn == ["notion"])
    }

    @Test func brokenFilesSayWhy() {
        #expect(throws: MCPServers.ParseError.self) { try MCPServers.parse(Data("nope".utf8)) }
        #expect(throws: MCPServers.ParseError.self) { try MCPServers.parse(Data("{}".utf8)) }
        #expect(throws: MCPServers.ParseError.self) { try MCPServers.parse(Data(#"{"mcpServers":{"bad":{}}}"#.utf8)) }
    }
}

struct ModelWindowsTests {
    @Test func theProviderWinsThenTheFamilyThenTheFallback() {
        let listed = [LLMModelInfo(id: "deepseek-v4.1-flash:cloud", providerName: "ollama", contextWindow: 163_840),
                      LLMModelInfo(id: "tiny", providerName: "ollama", contextWindow: nil)]
        #expect(ModelWindows.pick(model: "deepseek-v4.1-flash", provider: .ollama, listed: listed) == (163_840, .provider), "bare name matches the tagged id")
        #expect(ModelWindows.pick(model: "claude-opus-5-5", provider: .anthropic, listed: []) == (200_000, .family))
        #expect(ModelWindows.pick(model: "gpt-4o-mini", provider: .openai, listed: []) == (128_000, .family), "the longest pattern wins")
        #expect(ModelWindows.pick(model: "tiny", provider: .ollama, listed: listed) == (32_768, .assumed), "listed without a window")
        #expect(ModelWindows.pick(model: "mystery", provider: .anthropic, listed: []) == (200_000, .assumed))
    }
}

struct SessionTests {
    @Test func savedSessionNamesAreStablePerFolderAndSafe() {
        let a = SavedSessions.defaultName(for: URL(fileURLWithPath: "/Users/me/My Project"))
        #expect(a == SavedSessions.defaultName(for: URL(fileURLWithPath: "/Users/me/My Project")))
        #expect(a.hasPrefix("myproject-"))
        #expect(a != SavedSessions.defaultName(for: URL(fileURLWithPath: "/Users/me/other/My Project")), "same name, other place")
    }

    /// A launcher that leaves stdin open without writing must not hang sak
    /// (it did: reading to EOF on an idle pipe). Data that is there is read.
    @Test func anIdlePipeIsNoInputAndAFedPipeIsRead() {
        var idle: [Int32] = [0, 0]; #expect(pipe(&idle) == 0)
        defer { close(idle[0]); close(idle[1]) }
        #expect(readPipedInput(fd: idle[0], waitMilliseconds: 50) == "")
        var fed: [Int32] = [0, 0]; #expect(pipe(&fed) == 0)
        let text = "diff --git a b\n"
        _ = text.withCString { write(fed[1], $0, strlen($0)) }
        close(fed[1])
        #expect(readPipedInput(fd: fed[0], waitMilliseconds: 50) == "diff --git a b")
        close(fed[0])
    }

    @Test func exitCodesMatchTheHelpText() {
        #expect(RunOutcome(response: "ok", error: nil, summary: nil, deniedTools: []).exitCode == 0)
        #expect(RunOutcome(response: "", error: nil, summary: nil, deniedTools: ["edit_file"]).exitCode == 3)
        #expect(RunOutcome(response: "", error: AgentError.cancelled, summary: nil, deniedTools: []).exitCode == 130)
        #expect(RunOutcome(response: "", error: AgentError.maxTurnsReached(30), summary: nil, deniedTools: []).exitCode == 4)
        #expect(RunOutcome(response: "", error: SakError.usage("x"), summary: nil, deniedTools: []).exitCode == 1)
    }

    @Test func theLastParagraphIsTheSummary() {
        #expect(Session.lastParagraph("Did things.\n\nAll done:\nit works.") == "All done: it works.")
        #expect(Session.lastParagraph("") == "(no answer)")
    }

    @Test func modelChoiceResolvesFlagsThenSavedThenEnvThenDefault() {
        let env = Settings(values: ["SAK_PROVIDER": "anthropic", "SAK_MODEL": "claude-sonnet-5"])
        #expect(resolveChoice(Arguments(provider: .openai, model: "gpt-5.5"), settings: env, saved: nil) == ModelChoice(provider: .openai, model: "gpt-5.5"))
        #expect(resolveChoice(Arguments(), settings: env, saved: ModelChoice(provider: .gemini, model: "g")) == ModelChoice(provider: .gemini, model: "g"))
        #expect(resolveChoice(Arguments(), settings: env, saved: nil) == ModelChoice(provider: .anthropic, model: "claude-sonnet-5"))
        #expect(resolveChoice(Arguments(provider: .anthropic), settings: Settings(values: [:]), saved: nil).model == ProviderKind.anthropic.defaultModel)
        #expect(resolveChoice(Arguments(provider: .openai), settings: env, saved: nil).model == ProviderKind.openai.defaultModel, "SAK_MODEL belongs to SAK_PROVIDER")
    }
}
