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

    @Test func autoModeComesFromTheFlagOrTheSetting() {
        #expect(parseArgumentsForTest(["--auto"]).autoApprove)
        #expect(parseArgumentsForTest(["-y"]).autoApprove)
        #expect(!parseArgumentsForTest(["-r"]).autoApprove)
        #expect(Settings(values: ["SAK_AUTO": "1"]).autoMode && Settings(values: ["SAK_AUTO": "yes"]).autoMode)
        #expect(!Settings(values: ["SAK_AUTO": "0"]).autoMode && !Settings(values: [:]).autoMode)
    }

    @Test func approvalAnswersAreReadAsTyped() {
        #expect(ApprovalAnswer("y", hasServer: false) == .once)
        #expect(ApprovalAnswer(" Yes ", hasServer: false) == .once)
        #expect(ApprovalAnswer("a", hasServer: false) == .alwaysTool)
        #expect(ApprovalAnswer("A", hasServer: false) == .everything)
        #expect(ApprovalAnswer("s", hasServer: true) == .alwaysServer)
        // "s" with no MCP server to allow, an empty line, or anything else is a no.
        #expect(ApprovalAnswer("s", hasServer: false) == .no)
        #expect(ApprovalAnswer("", hasServer: true) == .no)
        #expect(ApprovalAnswer("/exit", hasServer: true) == .no)
        #expect(ApprovalAnswer("n", hasServer: true) == .no)
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

struct WelcomeTests {
    private func info(skills: Int = 14) -> Welcome.Info {
        Welcome.Info(
            version: "0.3.0-alpha", model: "kimi-k2.6:cloud", provider: "Ollama",
            folder: "~/projects/a-rather-long-folder-name/app", branch: "feature/a-long-branch-name",
            mode: "asks before changes", window: 262_144,
            notes: [("config", "~/.config/sak/.env")],
            toolGroups: Welcome.group(
                tools: ["read_file", "list_dir", "run_shell", "web_search", "use_skill", "custom_tool", "click", "list_pages"],
                mcpServerOf: ["click": "chrome_devtools", "list_pages": "chrome_devtools"]),
            toolCount: 8, skills: (1...max(1, skills)).map { "skill-number-\($0)" }.prefix(skills).map { $0 },
            warnings: ["docs: couldn't connect"])
    }

    private func visibleWidth(_ line: String) -> Int {
        line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).count
    }

    @Test func everyPanelRowIsExactlyAsWideAsTheBox() {
        for width in [30, 44, 60, 75, 76, 80, 100, 104, 200] {
            for color in [false, true] {
                let lines = Welcome.panel(info(), width: width, color: color)
                let expected = max(44, min(width, 104))
                for line in lines { #expect(visibleWidth(line) == expected, "width \(width), color \(color): \(line)") }
                #expect(lines.first?.contains("sak 0.3.0-alpha") == true)
            }
        }
    }

    @Test func withoutColourThePanelHasNoEscapeCodes() {
        #expect(!Welcome.panel(info(), width: 100, color: false).joined().contains("\u{1B}"))
        #expect(!Welcome.statusRule(model: "m", used: 10, window: 100, folder: "f", branch: nil, mode: "read-only",
                                    width: 80, color: false).contains("\u{1B}"))
    }

    @Test func thePanelSaysWhatTheAgentHas() {
        let text = Welcome.panel(info(), width: 104, color: false).joined(separator: "\n")
        #expect(text.contains("kimi-k2.6:cloud"))
        #expect(text.contains("chrome_devtools (2 tools)"))
        #expect(text.contains("custom_tool"))
        #expect(text.contains("8 tools · 14 skills"))
        #expect(text.contains("couldn't connect"))
        #expect(Welcome.panel(info(skills: 0), width: 104, color: false).joined().contains("Skills") == false)
    }

    @Test func theStatusRuleFillsTheWidthAndShowsHowFullTheContextIs() {
        let rule = Welcome.statusRule(model: "kimi", used: 131_072, window: 262_144, folder: "app", branch: "main",
                                      mode: "asks before changes", width: 90, color: false)
        #expect(rule.count == 90)
        #expect(rule.contains("ctx 131K/262K ▰▰▰▰▰▱▱▱▱▱ 50%"))
        #expect(rule.contains("app (main)"))
        // Too narrow for everything: cut to the width, never wrapped.
        #expect(Welcome.statusRule(model: "kimi", used: 0, window: 0, folder: "app", branch: nil, mode: "read-only",
                                   width: 30, color: false).count == 30)
    }

    @Test func numbersAndNamesAreShortened() {
        #expect(Welcome.short(950) == "950")
        #expect(Welcome.short(7234) == "7.2K")
        #expect(Welcome.short(8000) == "8K")
        #expect(Welcome.short(262_144) == "262K")
        #expect(Welcome.short(1_000_000) == "1M")
        #expect(Welcome.wrap(["a", "b", "c"], width: 20, maxLines: 2) == ["a, b, c"])
        #expect(Welcome.wrap(["alpha", "beta", "gamma", "delta", "epsilon"], width: 14, maxLines: 2) == ["alpha, beta,", "gamma, +2 more"])
        for row in Welcome.wrap((1...30).map { "name\($0)" }, width: 25, maxLines: 3) { #expect(row.count <= 25) }
        #expect(Welcome.shortPath("/Users/me/projects/x", home: "/Users/me") == "~/projects/x")
        #expect(Welcome.shortPath("/Users/me/a/very/long/path/to/some/deep/project/folder", home: "/Users/me", max: 20) == "~/…/project/folder")
    }
}

@MainActor struct SlashMenuTests {
    private let commands = SlashMenu.commands(from: Commands.help)

    @Test func theHelpTableBecomesMenuCommands() {
        #expect(commands.first == SlashMenu.Command(name: "/model", arguments: "[name|number]",
                                                    about: "show or switch the model (no name: pick from a list)"))
        #expect(commands.contains { $0.name == "/exit" && $0.arguments.isEmpty })
        // Everything the menu offers is something Enter can run.
        for command in commands { #expect(Commands.known.contains(command.name)) }
    }

    @Test func theMenuNarrowsWithWhatIsTyped() {
        #expect(SlashMenu.matches(for: "/", in: commands).count == commands.count)
        #expect(SlashMenu.matches(for: "/mo", in: commands).map(\.name) == ["/model"])
        // Names that start with the text first, then names that contain it.
        #expect(SlashMenu.matches(for: "/p", in: commands).map(\.name) == ["/provider", "/providers", "/mcp", "/help"])
        #expect(SlashMenu.matches(for: "/MO", in: commands).map(\.name) == ["/model"])
        #expect(SlashMenu.matches(for: "/zz", in: commands).isEmpty)
        // Not a command being typed: no menu.
        #expect(SlashMenu.matches(for: "", in: commands).isEmpty)
        #expect(SlashMenu.matches(for: "fix /this", in: commands).isEmpty)
        #expect(SlashMenu.matches(for: "/model ", in: commands).isEmpty)
        #expect(SlashMenu.matches(for: "/model sonnet", in: commands).isEmpty)
    }

    @Test func enterRunsTheFirstMatch() {
        func resolve(_ line: String) -> String { SlashMenu.resolve(line, in: commands, known: Commands.known) }
        #expect(resolve("/mo") == "/model")
        #expect(resolve("/mo sonnet") == "/model sonnet")
        #expect(resolve("/too") == "/tools")
        // A real name or alias is left alone, even when it is a prefix of another.
        #expect(resolve("/m") == "/m")
        #expect(resolve("/provider") == "/provider")
        #expect(resolve("/q") == "/q")
        // Nothing matches: left for "Unknown command". Not a command: untouched.
        #expect(resolve("/zz") == "/zz")
        #expect(resolve("explain /usr/bin") == "explain /usr/bin")
    }

    @Test func menuRowsFitTheTerminalAndMarkTheFirst() {
        let all = SlashMenu.matches(for: "/", in: commands)
        let rows = SlashMenu.rows(for: all, width: 60, maxRows: 16, color: false)
        #expect(rows.count == all.count)
        #expect(rows[0].hasPrefix("❯ /model"))
        #expect(rows[1].hasPrefix("  /provider"))
        for row in rows { #expect(row.count <= 59) }
        // More matches than rows: the last row says how many are left.
        let few = SlashMenu.rows(for: all, width: 100, maxRows: 5, color: false)
        #expect(few.count == 5)
        #expect(few.last == "  … \(all.count - 4) more — keep typing")
        #expect(SlashMenu.rows(for: [], width: 100, color: false).isEmpty)
        #expect(!SlashMenu.rows(for: all, width: 100, color: false).joined().contains("\u{1B}"))
    }

    @Test func drawingMakesRoomClearsAndComesBack() {
        let esc = "\u{1B}"
        let draw = SlashMenu.drawing(rows: ["a", "b"], previous: 0)
        #expect(draw == "\(esc)D\(esc)D\(esc)[2A\(esc)7\r\n\(esc)[Ja\r\nb\(esc)8")
        // A shorter menu still clears the longer one it replaces.
        #expect(SlashMenu.drawing(rows: ["a"], previous: 3).hasPrefix("\(esc)D\(esc)D\(esc)D\(esc)[3A"))
        // Nothing to show and nothing to clear: nothing is written.
        #expect(SlashMenu.drawing(rows: [], previous: 0).isEmpty)
        #expect(SlashMenu.drawing(rows: [], previous: 2) == "\(esc)D\(esc)D\(esc)[2A\(esc)7\r\n\(esc)[J\(esc)8")
    }
}
