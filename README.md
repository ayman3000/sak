# sak

<p>
  <img src="https://img.shields.io/badge/status-alpha-yellow" alt="Alpha">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6.2-orange" alt="Swift 6.2">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
</p>

**A lightweight coding agent for your terminal, written in Swift.** Reads your code, fixes bugs, runs tests and automates dev tasks with the model you choose — asking before it changes anything. Chat with it, pipe into it, or run it in CI.

Built on [SwiftAgentKit](https://github.com/ayman3000/SwiftAgentKit), the open-source engine behind [Naseem](https://naseemformac.com), the AI agent for Mac — about 1,400 lines on top of it.

> **Want it in a Mac app?** [Naseem](https://naseemformac.com) is the full desktop agent: it works in your projects, files and apps, and has memory and skills. Naseem Pro adds the iOS Simulator, Mac app control, sub-agents and a reviewer. `sak` and Naseem share project notes and skills, so you can switch between the terminal and the app at any time. [See how they work together ↓](#works-with-naseem)

A real session, as recorded (kimi-k2.6:cloud through Ollama; one long path shortened):

```
› the date parser test fails — find out why and fix it
→ list_dir path=.
  ✓ Package.swift ⏎ Sources/ ⏎ Tests/
→ search_files directory=. name=test
  ✓ …/DateKit/Tests/CoreTests/DateParserTests.swift
→ read_file path=Tests/CoreTests/DateParserTests.swift
  ✓ import XCTest ⏎ @testable import Core ⏎  ⏎ final class DateParserTests: XCTestCase { ⏎     func test…
→ list_dir path=Sources
  ✓ Core/
→ list_dir path=Sources/Core
  ✓ DateParser.swift
→ read_file path=Sources/Core/DateParser.swift
  ✓ import Foundation ⏎  ⏎ /// Parses the timestamps our server sends, e.g. "2025-12-29 14:30". ⏎ public…
The bug is in `DateParser.swift`: the format string uses `hh:mm` (12-hour) but the timestamp contains `14:30` (24-hour). It needs `HH:mm`.
? allow edit_file new_text=        formatter.dateFormat = "yyyy-MM-dd HH:mm" old_text=        formatter.dateFormat = "yyyy-MM-dd hh:mm" path=Sources/Core/DateParser.swift
  [y]es  [n]o  [a]lways for edit_file this session › y
→ edit_file new_text=        formatter.dateFormat = "yyyy-MM-dd HH:mm" old_text=        formatter.dateFormat = "yyyy-MM-dd hh:mm" path=Sources/Core/DateParser.swift
  ✓ Replaced 1 occurrence in Sources/Core/DateParser.swift.
? allow run_shell command=swift test --filter DateParserTests 2>&1
  [y]es  [n]o  [a]lways for run_shell this session › y
→ run_shell command=swift test --filter DateParserTests 2>&1
  ✓ exit 0 ⏎ [0/1] Planning build ⏎ Building for debugging... ⏎ [0/3] Write sources ⏎ [1/3] Write swift-…
The `DateParser` was failing because its `DateFormatter` format string used `hh:mm` (12-hour) but the server timestamps use 24-hour values like `14:30`. `hh:mm` only parses hours 01–12, so `14:30` returned `nil`.

**Fix:** Changed the format string from `yyyy-MM-dd hh:mm` to `yyyy-MM-dd HH:mm` in `Sources/Core/DateParser.swift`.

The `DateParserTests` now pass.
```

## What it does

- **Reads and changes code in one folder**: lists, searches and reads files, edits them in place (search-and-replace, never a rewrite you didn't see), writes new ones, runs build and test commands, fetches web pages, and searches the web with a Tavily key. File tools can't leave the folder you started in.
- **Asks before anything that changes something** — an edit, a shell command, an MCP tool that acts. Reads never ask. One keystroke approves a tool, a whole MCP server, or everything for the session.
- **Works with your MCP servers**: a browser (chrome-devtools), a database, a docs server — from `mcp.json` or, if you use Naseem, the servers you already set up there.
- **Any model you have**: Ollama (local or cloud), Anthropic, OpenAI, Gemini, OpenRouter; switch mid-conversation and keep the context.
- **Runs unattended**: one request from a script or CI, JSON out, exit codes that mean something; `--read-only` for reviews, `--auto` for pipelines you trust.
- **Remembers per folder**: `sak -c` continues the last conversation in this folder; with Naseem it shares project notes and skills.

## Why a terminal agent

- **Where the work already is.** Build output, test failures, git — pipe them straight in: `swift test 2>&1 | sak "why does this fail?"`. No copy-paste into a chat window.
- **Small prompts, fast turns.** sak sends the model a short system prompt, seven tool schemas and the files it actually read — not a transcript of everything. On the same tasks and the same model, that was a third to a quarter of the tokens of the larger agents and correspondingly faster (see *Measured*).
- **Scriptable.** It composes like any Unix tool: pre-commit hooks, CI steps, a nightly review, or another agent calling it.
- **Readable.** About 1,400 lines of Swift on a public engine: you can see exactly what runs in your folder.

## Use cases

- *Fix this failing test* — the session above: find, read, edit, run the test, report.
- *Review before I commit* — `git diff --cached | sak --read-only "bugs? one paragraph"`.
- *Explain this codebase to me* — `sak -r "how does the sync layer work? files and flow"`.
- *Small, well-defined changes* — add a flag, rename safely, write the missing test, update a README from the code.
- *Front-end checks with a browser* — with chrome-devtools: open the local page, read the console, click through a flow.
- *Batch work in CI* — label issues, lint prose, generate a changelog, each as one `sak --json` call.

Not (yet) a good fit: a multi-day refactor across a large codebase, work that needs a plan you review first, or anything where the tests themselves are the question — see *Status and limits*.

## Install

Requires macOS 14+ and Swift 6.2 (Xcode 26).

```bash
git clone https://github.com/ayman3000/sak.git
cd sak
make install        # builds a release binary and links it to /usr/local/bin/sak
```

If `/usr/local/bin` isn't writable, run `sudo make install`, or install somewhere else with `make install PREFIX=~/.local`. `make install` links to the binary inside the clone, so keep the folder. `make uninstall` removes the link.

`make smoke` runs three real requests (a question, a read-only review of this repo, an edit in a temporary folder) and prints their turns, tool calls and tokens — the quick check after changing sak or SwiftAgentKit.

Then add your keys (only the ones you use):

```bash
mkdir -p ~/.config/sak && cp .env.example ~/.config/sak/.env && open -e ~/.config/sak/.env
```

With no keys set, `sak` uses [Ollama](https://ollama.com) on your Mac. The default model, `kimi-k2.6:cloud`, is an Ollama cloud model, so it needs `ollama signin` first. To stay fully local, pick a model you've pulled, such as `sak -m llama3.2`, or choose one with `/model`.

## Use it

```bash
sak                                   # chat in the current folder
sak "add a --verbose flag to the CLI" # one request, then exit
sak -c                                # continue this folder's last chat
```

| Option | What it does |
|---|---|
| `-P`, `--provider <name>` | use a provider: `ollama`, `anthropic`, `openai`, `gemini`, `openrouter` |
| `-m`, `--model <name>` | use a model |
| `-r`, `--read-only` | no edit or shell tools |
| `-y`, `--yes`, `--auto` | auto mode: edits, shell commands and MCP tools run without asking (`SAK_AUTO=1` in `.env` does the same for every run) |
| `-c`, `--continue` | continue this folder's last chat |
| `--json` | print one JSON result (for scripts) |
| `-q`, `--quiet` | print only the answer, no progress |
| `--turns <n>` | the maximum number of agent turns per request (default 30) |
| `-v`, `--version` · `-h`, `--help` | version · help |

### In the chat

| Command | What it does |
|---|---|
| `/model` | show the model and pick another from a numbered list |
| `/model claude-opus-5-5` | switch model by name |
| `/provider anthropic` | switch provider: `ollama`, `anthropic`, `openai`, `gemini`, `openrouter` |
| `/providers` | which providers are ready, and which need a key |
| `/tools` · `/skills` · `/notes` | what the agent can use and knows |
| `/yes` | toggle auto-approve for edits and shell commands |
| `/usage` | tokens and tool calls so far |
| `/save` · `/resume` | save and reload conversations |
| `/clear` · `/exit` | fresh conversation · quit |

Switching model keeps the conversation, so you can plan with one model and finish with another. Your choice is remembered for next time.

↑/↓ go through your history, Ctrl-R searches it, Ctrl-C stops a running request, Ctrl-D quits. End a line with `\` to keep typing on the next.

### In scripts and CI

Pipe anything in. Progress goes to stderr, so stdout has only the answer:

```bash
swift test 2>&1 | sak "why does this fail? one paragraph"
git diff --staged | sak "review this diff for bugs" > review.md
```

`--read-only` removes the edit and shell tools — safe to run on any repo. `--json` prints one result object:

```bash
sak --read-only --json "list every TODO with its file and line"
```

```json
{
  "ok": true, "exit_code": 0,
  "provider": "anthropic", "model": "claude-sonnet-5",
  "response": "…", "turns": 4, "tool_calls": 3, "tool_errors": 0,
  "denied_tools": [], "elapsed_seconds": 12.4, "context_window": 200000,
  "usage": { "input_tokens": 18234, "output_tokens": 612, "cached_tokens": 9000 }
}
```

When nobody is there to approve a change, `sak` stops instead of trying something else, and exits with code 3. Pass `-y` (or `--auto`) to allow changes in a pipeline you trust; another agent driving `sak` — Claude Code calling `sak --auto --json "…"`, say — gets one JSON result back and never a prompt.

| Exit code | Meaning |
|---|---|
| 0 | done |
| 1 | error (model or network) |
| 2 | bad usage or missing API key |
| 3 | a tool needed approval and was denied |
| 4 | hit the turn limit (`--turns`) |
| 130 | stopped with Ctrl-C |

### From another agent — Claude Code, Naseem, your own scripts

sak is a command, so any agent that can run commands can use it as a worker: a second opinion, a parallel task in another folder, or a cheap model doing the mechanical part.

```bash
# Claude Code (or anything with a shell) asks sak for a read-only review and gets one JSON object back
sak --read-only --json -q "Review this repository for obvious bugs; list file:line and a sentence each."

# a trusted pipeline: let sak make the change, with the result and exit code to act on
SAK_AUTO=1 sak --json -q "Add a --version flag that prints the version from Package.swift, with a test."
```

Rules that make this safe to automate: `--read-only` has no edit or shell tools at all; without `--auto`/`SAK_AUTO=1` a change that needs approval **stops** (exit 3) instead of trying another way; `--json` always returns one object with `ok`, `exit_code`, `response`, `usage`, and never a prompt; nothing is read from stdin when stdin is idle.

A pre-commit review, for example:

```bash
# .git/hooks/pre-commit
git diff --cached | sak --read-only -q "Reply BLOCK and the reason if this diff has an obvious bug, else OK" | grep -q '^OK'
```

## Settings

`sak` reads `KEY=value` files, like python-dotenv. The first place that has a key wins:

1. the environment (`export ANTHROPIC_API_KEY=…`)
2. `./.env` in the folder you run `sak` in
3. `~/.config/sak/.env`

| Key | For |
|---|---|
| `ANTHROPIC_API_KEY` · `OPENAI_API_KEY` · `GEMINI_API_KEY` · `OPENROUTER_API_KEY` | the cloud providers |
| `TAVILY_API_KEY` | turns on the `web_search` tool ([tavily.com](https://tavily.com), free tier) |
| `SAK_PROVIDER` · `SAK_MODEL` | the default provider and model |
| `OLLAMA_HOST` | an Ollama server that isn't `localhost:11434` |
| `SAK_AUTO=1` | auto mode for every run, same as `-y` — for a tool that drives `sak` and can't answer prompts |
| `SAK_NASEEM=0` | don't read Naseem's notes, skills and MCP servers |
| `SAK_CONFIG_DIR` | use another folder than `~/.config/sak` (`.env`, `mcp.json`, skills, sessions) |

Keys from `.env` files aren't put in the environment, so a shell command the agent runs doesn't inherit them — but a shell command can still read the file, as you could. Keys you `export` in your shell are inherited like any program's environment. Keep keys in `~/.config/sak/.env` rather than a project's `.env`: the agent's file tools reach your project, not your home folder.

## MCP servers

Tools from [MCP](https://modelcontextprotocol.io) servers join the agent's own. Put them in `~/.config/sak/mcp.json` (every project) or `./.sak/mcp.json` (one project), in the same shape Claude Code and Claude Desktop use, so a config can be pasted across:

```json
{ "mcpServers": {
    "chrome-devtools": { "command": "npx", "args": ["-y", "chrome-devtools-mcp@latest", "--isolated"] },
    "docs": { "url": "https://example.com/mcp" } } }
```

If you use Naseem, its enabled MCP servers come along automatically — read from its settings, nothing written back — except servers that need a sign-in (their tokens live in Naseem); `SAK_NASEEM=0` turns that off, and a same-named entry in `mcp.json` wins.

A tool the server marks read-only runs like `read_file`; any other asks first, like an edit (`-y` and `/yes` apply). `--read-only` keeps only the read-only ones. `/mcp` lists the servers and their tools; the banner says how many tools came from where. Every server adds its tool schemas to every request — a browser server is a few thousand tokens per call — so list the ones you use.

## Safety

- File tools only reach the folder you started `sak` in (paths are resolved, symlinks included, before the check).
- Shell commands can reach anything your user can — that is why each one asks first, unless you pass `-y` or turn on `/yes`. Edits and MCP tools that change things ask too. At the prompt: `y` once, `a` always for that tool, `s` for every tool of that MCP server, `A` for everything, all for this session.
- `--read-only` has no edit or shell tools at all.

## Works with Naseem

If you use [Naseem](https://naseemformac.com), `sak` shares what it knows:

- **Project notes.** Naseem keeps `naseem/project.md`, `rules.md`, `roadmap.md` and `journal.md` in a project. `sak` follows those rules, sees the open roadmap items, and adds a line to the journal when it changed something (in Naseem's own `[build]` format, marked `sak:`) — so Naseem knows what you did in the terminal, and the other way round. A question answered leaves no entry.
- **Skills.** Naseem's skills are available in `sak` too. Skills `sak` learns go to `~/.config/sak/skills`; it never changes Naseem's.
- **MCP servers.** The servers you enabled in Naseem work in `sak` too (see [MCP servers](#mcp-servers)).

A typical day: plan a feature with Naseem, fix a failing test with `sak` in the terminal, then let Naseem pick up from the journal. Neither tool loses track of what the other did.

| | `sak` | Naseem |
|---|---|---|
| Where | the terminal, scripts, CI | a native Mac app |
| Models | Ollama, Anthropic, OpenAI, Gemini, OpenRouter | those and more, with a reviewer and a helper model |
| Code, files, shell, web | ✓ | ✓ |
| Project notes and skills | shared: reads them, journals its work | full memory, lessons, skills |
| Workflows on a schedule, Telegram | — | ✓ |
| iOS Simulator, Mac app control, sub-agents | — | Pro |

For the iOS Simulator, Mac app control, sub-agents and a reviewer in a real Mac app, get **[Naseem Pro](https://naseemformac.com)**.

## Build your own

`sak` is about 1,400 lines of Swift on top of SwiftAgentKit, and it's meant to be read as an example of a real agent. Start at [`Sources/sak/Session.swift`](Sources/sak/Session.swift): it builds the agent, its tools and its approval prompt.

```
            SwiftAgentKit            the agent loop, tools, memory, skills
                 │
        ┌────────┴────────┐
       sak              Naseem       sak: Terminal.swift (prompt, Ctrl-C),
    terminal           Mac app            Session.swift (agent, tools, approvals),
        └────────┬────────┘              ProjectContext.swift (the shared notes and skills)
                 │
       naseem/ notes · skills        in your project folder and ~/Library/Application Support/Naseem
```

The engine's own examples are in [SwiftAgentKit/Examples](https://github.com/ayman3000/SwiftAgentKit/tree/main/Examples).

## Measured

On an internal benchmark of six coding tasks (Swift, Python, TypeScript, one React app from scratch; hidden tests grade the result), run the same day on the same model:

| | kimi-k2.6:cloud (Ollama Cloud, no prompt caching) | Claude Haiku 5.5 (Anthropic API) |
|---|---|---|
| sak | 10/12 pass · 1,013 s total · 89K tokens in (median) | 6/6 · 274 s · 599K in (total) |
| Claude Code | 10/12 · 2,691 s · 308K in — *different day* | 5/6 · 356 s · 2.27M in |
| Hermes | 12/12 · 4,173 s · 155K in — *different day* | — |

On the three tasks re-run the same day on kimi, sak was 1.2–2× faster than Claude Code and Hermes with a third to a quarter of the tokens; with Anthropic's prompt caching the time gap narrows to about 1.3× and the token gap stays. Small tasks, one person's harness, your mileage will vary — the point is the shape: fewer tokens per call, fewer calls. Both failures were the model editing a protected test or papering over a test environment; the prompt now forbids the first.

## Status and limits

`sak` is **alpha** (0.3.0-alpha). Commands, flags and the `--json` fields may change before 1.0. CI builds it and runs its tests on every change; `make smoke` runs three real requests against a model. Tested day to day with Ollama; Anthropic and OpenAI through the benchmark; Gemini and OpenRouter use the same code with less real-world time.

What it doesn't do yet, honestly:

- **No plan step.** It reads, then acts; there is no plan you approve first. For a big change, ask for the plan as a question (`-r`) before asking for the change.
- **No sandbox for shell commands.** They run as you, after you approve them (or always, with `--auto`). File tools are confined to the folder; shell commands are not.
- **Keys in `.env` are readable** by a shell command you approve, like any file. Keep keys in `~/.config/sak/.env`, not in a project.
- **It can still touch tests you asked it to make pass** — the prompt forbids it, models sometimes do it anyway. Protected tests in a hidden copy are the real guard.
- **One conversation per folder** with `-c`; no branching, no sharing across machines.
- **Tokens, not dollars**: `/usage` shows counts, not cost.
- **MCP servers cost tokens**: every server's tool schemas ride along on every request; a browser server is a few thousand tokens per call. List the ones you use.
- **macOS only**, Swift 6.2 to build; no Homebrew formula yet (coming).

Please [report anything that breaks](https://github.com/ayman3000/sak/issues).

## License

MIT — see [LICENSE](LICENSE).
