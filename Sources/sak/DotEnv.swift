// Settings from .env files, like python-dotenv.
//
// Looked up in this order — the first one that has a key wins:
//   1. the real environment (export TAVILY_API_KEY=… in the shell)
//   2. ./.env              in the folder sak is started in (per project)
//   3. ~/.config/sak/.env  (your keys for every project)
//
// Values are kept inside sak, not exported, so commands the agent runs
// with run_shell never see your API keys.

import Foundation

struct Settings {
    private var values: [String: String] = [:]
    /// The .env files that were found and read, in priority order.
    private(set) var loadedFiles: [String] = []

    /// sak's own folder: ~/.config/sak, or $SAK_CONFIG_DIR.
    static var configDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["SAK_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/sak", isDirectory: true)
    }

    static var globalFile: URL { configDirectory.appendingPathComponent(".env") }

    init(projectDirectory: URL) {
        // Lowest priority first, so later files overwrite earlier ones.
        let files = [Self.globalFile, projectDirectory.appendingPathComponent(".env")]
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            values.merge(Self.parse(text)) { _, new in new }
            loadedFiles.insert(file.path, at: 0)
        }
        values.merge(ProcessInfo.processInfo.environment) { _, env in env }
    }

    /// For tests: settings from values alone, no files or environment.
    init(values: [String: String]) { self.values = values }

    subscript(key: String) -> String? {
        guard let value = values[key], !value.isEmpty else { return nil }
        return value
    }

    /// KEY=VALUE lines. Supports `#` comments, blank lines, an optional
    /// `export ` prefix, and single- or double-quoted values.
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'",
               let end = value.dropFirst().firstIndex(of: quote) {
                value = String(value[value.index(after: value.startIndex)..<end])
            } else if let hash = value.range(of: " #") {
                value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}
