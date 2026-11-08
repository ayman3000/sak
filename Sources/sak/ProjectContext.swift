// What sak shares with Naseem (naseemformac.com):
//
//  • Project notes — the `naseem/` folder Naseem keeps in a project
//    (project.md, rules.md, roadmap.md, journal.md). sak reads them into the
//    system prompt and adds a line to journal.md after each request, so the
//    app and the terminal know what the other did.
//  • Skills — Naseem's skills (~/Library/Application Support/Naseem/skills)
//    plus sak's own (~/.config/sak/skills). Skills sak learns are saved in its
//    own folder; Naseem's are only read.
//
// Set SAK_NASEEM=0 to turn all of this off.

import Foundation
import SwiftAgentKit

struct ProjectContext: Sendable {
    let notesDirectory: URL?
    let skillStore: (any AgentSkillStore)?
    private let skillCounts: (sak: Int, naseem: Int)

    static var naseemSkills: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Naseem/skills", isDirectory: true)
    }
    static var sakSkills: URL { Settings.configDirectory.appendingPathComponent("skills", isDirectory: true) }

    init(projectDirectory: URL, settings: Settings) {
        guard settings["SAK_NASEEM"] != "0" else {
            notesDirectory = nil
            skillStore = nil
            skillCounts = (0, 0)
            return
        }
        let notes = projectDirectory.appendingPathComponent("naseem", isDirectory: true)
        var isDirectory: ObjCBool = false
        notesDirectory = FileManager.default.fileExists(atPath: notes.path, isDirectory: &isDirectory)
            && isDirectory.boolValue ? notes : nil

        let sakCount = Self.countSkills(in: Self.sakSkills)
        let naseemCount = Self.countSkills(in: Self.naseemSkills)
        skillCounts = (sakCount, naseemCount)
        skillStore = SharedSkillStore(own: Self.sakSkills,
                                      readOnly: naseemCount > 0 ? Self.naseemSkills : nil)
    }

    // MARK: - Notes in the prompt

    /// The notes as a system-prompt section, or nil when there are none.
    func promptSection() -> String? {
        guard let dir = notesDirectory else { return nil }
        var parts: [String] = []
        // Whole files, capped: the brief and the rules are short and always matter.
        for (file, cap) in [("project.md", 6000), ("rules.md", 6000)] {
            if let text = read(dir, file) {
                parts.append("### naseem/\(file)\n\(capped(text, cap))")
            }
        }
        // A roadmap can be long; its open items are what matter.
        if let roadmap = read(dir, "roadmap.md") {
            parts.append("### naseem/roadmap.md (open items)\n\(capped(Self.openItems(roadmap), 4000))")
        }
        // Only the latest journal lines: what happened most recently.
        if let journal = read(dir, "journal.md") {
            let entries = journal.split(separator: "\n").filter { $0.hasPrefix("- ") }.suffix(12)
            if !entries.isEmpty {
                parts.append("### naseem/journal.md (latest entries)\n" + entries.joined(separator: "\n"))
            }
        }
        guard !parts.isEmpty else { return nil }
        return """
        ## Project notes (shared with Naseem)
        This project keeps notes in naseem/. Follow its rules. Read the full files with \
        read_file when you need more. When you finish a roadmap item, mark it done in naseem/roadmap.md.

        \(parts.joined(separator: "\n\n"))
        """
    }

    /// One line for the chat banner.
    var summaryLine: String? {
        var bits: [String] = []
        if notesDirectory != nil { bits.append("project notes from naseem/") }
        let total = skillCounts.sak + skillCounts.naseem
        if total > 0 {
            bits.append(skillCounts.naseem > 0 ? "\(total) skills (\(skillCounts.naseem) from Naseem)" : "\(total) skills")
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    // MARK: - Journal

    /// Adds `- 2026-11-08 18:40 — [sak] Asked … → …` to naseem/journal.md,
    /// in Naseem's own format. Only when the journal already exists.
    func appendJournal(request: String, outcome: String) {
        guard let dir = notesDirectory else { return }
        let file = dir.appendingPathComponent("journal.md")
        guard FileManager.default.fileExists(atPath: file.path),
              let handle = try? FileHandle(forUpdating: file) else { return }
        defer { try? handle.close() }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let line = "- \(formatter.string(from: Date())) — [sak] Asked \(Self.clip(request, 120)) → \(Self.clip(outcome, 160))\n"
        _ = try? handle.seekToEnd()
        // Start on a fresh line even if the file doesn't end with one.
        if let size = try? handle.offset(), size > 0 {
            try? handle.seek(toOffset: size - 1)
            let last = try? handle.read(upToCount: 1)
            _ = try? handle.seekToEnd()
            if last != Data("\n".utf8) { handle.write(Data("\n".utf8)) }
        }
        handle.write(Data(line.utf8))
    }

    // MARK: - Helpers

    private func read(_ dir: URL, _ file: String) -> String? {
        guard let text = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func capped(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n…(truncated — read the file for the rest)" : text
    }

    /// The roadmap without its `## Done` sections.
    static func openItems(_ roadmap: String) -> String {
        var kept: [Substring] = []
        var skipping = false
        for line in roadmap.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") || line.hasPrefix("# ") {
                skipping = line.lowercased().contains("done") || line.lowercased().contains("completed")
            }
            if !skipping { kept.append(line) }
        }
        let open = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return open.isEmpty ? "(everything on the roadmap is done)" : open
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    private static func countSkills(in dir: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") }.count
    }
}

/// Skills from sak's own folder plus Naseem's, read-only. A skill in sak's
/// folder wins over a Naseem skill with the same name. New skills go to sak's folder.
struct SharedSkillStore: AgentSkillStore {
    let own: FileAgentSkillStore
    let naseem: URL?

    init(own ownDirectory: URL, readOnly naseemDirectory: URL?) {
        own = FileAgentSkillStore(directory: ownDirectory)
        naseem = naseemDirectory
    }

    func save(_ skill: AgentSkill) async throws { try await own.save(skill) }

    func delete(name: String) async throws {
        let mine = try await own.loadAll()
        guard mine.contains(where: { $0.name == name }) else {
            throw SakError.usage("'\(name)' is a Naseem skill; edit it in Naseem")
        }
        try await own.delete(name: name)
    }

    func loadAll() async throws -> [AgentSkill] {
        let mine = try await own.loadAll()
        // Read Naseem's folder without the store's init, which would create it.
        guard let naseem, FileManager.default.fileExists(atPath: naseem.path) else { return mine }
        let theirs = try await FileAgentSkillStore(directory: naseem).loadAll()
        let names = Set(mine.map(\.name))
        return mine + theirs.filter { !names.contains($0.name) }
    }
}
