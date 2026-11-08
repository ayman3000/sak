// A model's context window — what the agent trims and compacts against.
// Until 0.3 it was 128,000 for every model: too small for Claude and Gemini
// (needless compaction), too big for most local models (requests refused).
//
// Order: the provider's own answer (Ollama reports each model's context
// length; Gemini lists input limits) → the model family (the published
// window of claude-*, gpt-5*, gemini-3* …) → a per-provider fallback.

import Foundation
import LLMProviderKit

enum ModelWindows {
    /// Published windows by family, matched on the lowercased id; the longest
    /// matching pattern wins ("gpt-4o" over "gpt-4"). Same table as Naseem's.
    static let families: [(pattern: String, window: Int)] = [
        ("gpt-5", 1_000_000), ("gpt-4.1", 1_000_000), ("gpt-4o", 128_000), ("gpt-4", 128_000),
        ("o4", 200_000), ("o3", 200_000), ("o1", 200_000),
        ("claude", 200_000),
        ("gemini-3", 1_000_000), ("gemini-2.5", 1_000_000), ("gemini-2", 1_000_000), ("gemini-1.5", 1_000_000),
        ("llama-3", 128_000), ("qwen", 128_000), ("glm", 128_000), ("kimi", 128_000), ("deepseek", 128_000),
    ]

    /// When nothing is known: a local model is small, a hosted one isn't.
    static func fallback(_ provider: ProviderKind) -> Int {
        switch provider {
        case .ollama: 32_768
        case .anthropic: 200_000
        case .openai, .gemini, .openrouter: 128_000
        }
    }

    enum Source: String { case provider, family, assumed }

    /// Pure — unit-tested. `listed` is what the provider reported for its
    /// models (may be empty or stale); the id matches with or without an
    /// Ollama tag ("deepseek-v4.1-flash" ~ "deepseek-v4.1-flash:cloud").
    static func pick(model: String, provider: ProviderKind, listed: [LLMModelInfo]) -> (window: Int, source: Source) {
        let id = model.lowercased()
        let bare = id.split(separator: ":").first.map(String.init) ?? id
        if let hit = listed.first(where: { m in
            let mid = m.id.lowercased()
            return mid == id || (mid.split(separator: ":").first.map(String.init) ?? mid) == bare
        }), let window = hit.contextWindow, window > 0 {
            return (window, .provider)
        }
        if let family = families.filter({ id.contains($0.pattern) }).max(by: { $0.pattern.count < $1.pattern.count }) {
            return (family.window, .family)
        }
        return (fallback(provider), .assumed)
    }

    /// Asks the provider for its list, but never waits long for it: a model
    /// list is a nicety, the request is the point. Ollama answers locally in
    /// milliseconds; a hosted provider that is slow or offline is skipped.
    static func listed(from provider: any LLMProvider, timeout: Duration = .seconds(3)) async -> [LLMModelInfo] {
        await withTaskGroup(of: [LLMModelInfo]?.self) { group in
            group.addTask { try? await provider.availableModels() }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }
}
