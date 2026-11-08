// The model providers sak can talk to, through LLMProviderKit.

import Foundation
import LLMProviderKit
import LLMProviderKitOllama
import LLMProviderKitAnthropic
import LLMProviderKitOpenAI
import LLMProviderKitGemini
import LLMProviderKitOpenRouter

enum ProviderKind: String, CaseIterable, Codable {
    case ollama, anthropic, openai, gemini, openrouter

    var displayName: String {
        switch self {
        case .ollama: "Ollama"
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .gemini: "Google Gemini"
        case .openrouter: "OpenRouter"
        }
    }

    /// The settings key holding this provider's API key (nil: no key needed).
    var keyName: String? {
        switch self {
        case .ollama: nil
        case .anthropic: "ANTHROPIC_API_KEY"
        case .openai: "OPENAI_API_KEY"
        case .gemini: "GEMINI_API_KEY"
        case .openrouter: "OPENROUTER_API_KEY"
        }
    }

    var defaultModel: String {
        switch self {
        case .ollama: "kimi-k2.6:cloud"
        case .anthropic: AnthropicModel.sonnet5
        case .openai: OpenAIModel.gpt55
        case .gemini: GeminiModel.flash36
        case .openrouter: "anthropic/claude-sonnet-5"
        }
    }

    /// Accepts the full name or a short alias (`claude`, `gpt`, `google`, `or`).
    init?(alias: String) {
        switch alias.lowercased() {
        case "ollama", "local": self = .ollama
        case "anthropic", "claude": self = .anthropic
        case "openai", "gpt", "chatgpt": self = .openai
        case "gemini", "google": self = .gemini
        case "openrouter", "or": self = .openrouter
        default: return nil
        }
    }

    func apiKey(in settings: Settings) -> String? {
        guard let keyName else { return nil }
        if self == .gemini { return settings[keyName] ?? settings["GOOGLE_API_KEY"] }
        return settings[keyName]
    }

    /// Why this provider can't be used right now, or nil when it can.
    func unavailableReason(in settings: Settings) -> String? {
        guard let keyName, apiKey(in: settings) == nil else { return nil }
        return "needs \(keyName) in ~/.config/sak/.env"
    }

    func makeProvider(model: String, settings: Settings) throws -> any LLMProvider {
        if let reason = unavailableReason(in: settings) {
            throw SakError.usage("\(displayName) \(reason)")
        }
        let key = apiKey(in: settings) ?? ""
        switch self {
        case .ollama:
            let host = settings["OLLAMA_HOST"].flatMap(Self.ollamaURL) ?? URL(string: "http://localhost:11434")!
            return OllamaProvider(configuration: OllamaProvider.local(model: model, baseURL: host))
        case .anthropic:
            return AnthropicProvider(configuration: AnthropicProvider.anthropic(apiKey: key, model: model))
        case .openai:
            return OpenAIProvider(configuration: OpenAIProvider.openAI(apiKey: key, model: model))
        case .gemini:
            return GeminiProvider(configuration: GeminiProvider.gemini(apiKey: key, model: model))
        case .openrouter:
            return OpenRouterProvider(configuration: OpenRouterProvider.openRouter(apiKey: key, model: model),
                                      appName: "sak")
        }
    }

    /// OLLAMA_HOST may be `host:port` or a full URL.
    private static func ollamaURL(_ value: String) -> URL? {
        URL(string: value.contains("://") ? value : "http://\(value)")
    }
}

enum SakError: Error, CustomStringConvertible {
    case usage(String)
    var description: String {
        switch self { case .usage(let message): message }
    }
}

/// The provider + model in use, remembered between runs in ~/.config/sak/config.json
/// so a `/model` choice sticks, like Claude Code.
struct ModelChoice: Codable, Equatable {
    var provider: ProviderKind
    var model: String

    static var file: URL {
        Settings.globalFile.deletingLastPathComponent().appendingPathComponent("config.json")
    }

    static func saved() -> ModelChoice? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(ModelChoice.self, from: data)
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Self.file, options: .atomic)
    }
}
