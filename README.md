# sak

<p>
  <img src="https://img.shields.io/badge/status-alpha-yellow" alt="Alpha">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6.2-orange" alt="Swift 6.2">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
</p>

**A coding agent for your terminal, written in Swift.** Chat with it, pipe into it, or run it in CI. It reads your code, edits files, runs commands and searches the web — asking before it changes anything.

`sak` is built on [SwiftAgentKit](https://github.com/ayman3000/SwiftAgentKit), the open-source engine behind [Naseem](https://naseemformac.com), the AI agent for Mac.

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
| `-y`, `--yes` | approve edits and shell commands without asking |
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

When nobody is there to approve a change, `sak` stops instead of trying something else, and exits with code 3. Pass `-y` to allow changes in a pipeline you trust.

| Exit code | Meaning |
|---|---|
| 0 | done |
| 1 | error (model or network) |
| 2 | bad usage or missing API key |
| 3 | a tool needed approval and was denied |
| 4 | hit the turn limit (`--turns`) |
| 130 | stopped with Ctrl-C |

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
| `SAK_NASEEM=0` | don't read Naseem's notes and skills |
| `SAK_CONFIG_DIR` | use another folder than `~/.config/sak` |

Keys from `.env` files aren't put in the environment, so a shell command the agent runs doesn't inherit them — but a shell command can still read the file, as you could. Keys you `export` in your shell are inherited like any program's environment. Keep keys in `~/.config/sak/.env` rather than a project's `.env`: the agent's file tools reach your project, not your home folder.

## Safety

- File tools only reach the folder you started `sak` in (paths are resolved, symlinks included, before the check).
- Every edit and shell command asks first, unless you pass `-y` or turn on `/yes`.
- `--read-only` has no edit or shell tools at all.

## Works with Naseem

If you use [Naseem](https://naseemformac.com), `sak` shares what it knows:

- **Project notes.** Naseem keeps `naseem/project.md`, `rules.md`, `roadmap.md` and `journal.md` in a project. `sak` follows those rules, sees the open roadmap items, and adds a line to the journal when it changed something (in Naseem's own `[build]` format, marked `sak:`) — so Naseem knows what you did in the terminal, and the other way round. A question answered leaves no entry.
- **Skills.** Naseem's skills are available in `sak` too. Skills `sak` learns go to `~/.config/sak/skills`; it never changes Naseem's.

A typical day: plan a feature with Naseem, fix a failing test with `sak` in the terminal, then let Naseem pick up from the journal. Neither tool loses track of what the other did.

For the iOS Simulator, Mac app control, sub-agents and a reviewer in a real Mac app, get **[Naseem Pro](https://naseemformac.com)**.

## Build your own

`sak` is about 1,400 lines of Swift on top of SwiftAgentKit, and it's meant to be read as an example of a real agent. Start at [`Sources/sak/Session.swift`](Sources/sak/Session.swift): it builds the agent, its tools and its approval prompt.

## Status

`sak` is **alpha** (0.2.0-alpha). Commands, flags and the `--json` fields may change before 1.0. It's been tested day to day with Ollama; CI builds it and runs its tests on every change, and `make smoke` runs three real requests against a model. The Anthropic, OpenAI, Gemini and OpenRouter providers use the same code but have had less real-world testing. Please [report anything that breaks](https://github.com/ayman3000/sak/issues).

## License

MIT — see [LICENSE](LICENSE).
