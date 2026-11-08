// web_search — web search through the Tavily API (https://tavily.com).
// Needs TAVILY_API_KEY in the environment.

import Foundation
import SwiftAgentKit

struct TavilySearchTool: AgentTool {
    let name = "web_search"
    let description = """
    Search the web and return the most relevant pages with a short extract of each, \
    plus a direct answer when one is available. Use it for current events, docs, \
    error messages, library versions — anything you don't know or that may have changed. \
    To read a whole page from the results, use fetch_url on its URL.
    """
    let parameters = ToolParameters(
        properties: [
            "query": ToolParameterProperty(type: "string", description: "What to search for, phrased like a search-engine query."),
            "max_results": ToolParameterProperty(type: "integer", description: "How many results to return, 1–10. Default 5."),
            "topic": ToolParameterProperty(type: "string", description: "`general` (default) or `news` for recent events."),
            "deep": ToolParameterProperty(type: "boolean", description: "Slower, more thorough search (costs 2 credits instead of 1). Default false."),
        ],
        required: ["query"]
    )

    var inputExamples: [String] { [
        #"{"query": "swift-syntax 603 release notes"}"#,
        #"{"query": "Ollama release this week", "topic": "news", "max_results": 3}"#,
    ] }

    // Only reads from the web, so it may run alongside other read-only calls.
    var isReadOnly: Bool { true }
    // A retry would spend a second credit; don't.
    var retriesTransientFailures: Bool { false }

    let apiKey: String
    var session: URLSession = .shared

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let query = (parameters["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "web_search requires a non-empty `query`.")
        }
        let maxResults = min(max((parameters["max_results"] as? Int) ?? 5, 1), 10)
        let topic = (parameters["topic"] as? String) == "news" ? "news" : "general"
        let deep = (parameters["deep"] as? Bool) ?? false

        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "max_results": maxResults,
            "topic": topic,
            "search_depth": deep ? "advanced" : "basic",
            "include_answer": true,
        ] as [String: Any])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .error(toolCallId: "", toolName: name, message: "web_search failed: \(error.localizedDescription)")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let body = String(decoding: data.prefix(500), as: UTF8.self)
            let hint = switch status {
            case 401: " (check TAVILY_API_KEY)"
            case 429: " (rate limited — wait and retry)"
            case 432, 433: " (Tavily plan or credit limit reached)"
            default: ""
            }
            return .error(toolCallId: "", toolName: name, message: "Tavily returned HTTP \(status)\(hint): \(body)")
        }

        guard let json = try? JSONDecoder().decode(TavilyResponse.self, from: data) else {
            return .error(toolCallId: "", toolName: name, message: "Could not read Tavily's response.")
        }
        return .success(toolCallId: "", toolName: name, result: json.rendered(for: query))
    }
}

private struct TavilyResponse: Decodable {
    struct Result: Decodable {
        let title: String?
        let url: String
        let content: String?
    }
    let answer: String?
    let results: [Result]

    func rendered(for query: String) -> String {
        var out = "Search: \(query)\n"
        if let answer, !answer.isEmpty { out += "\nAnswer: \(answer)\n" }
        if results.isEmpty { return out + "\nNo results." }
        for (i, r) in results.enumerated() {
            out += "\n[\(i + 1)] \(r.title ?? r.url)\n\(r.url)\n"
            if let content = r.content, !content.isEmpty {
                out += String(content.prefix(800)) + "\n"
            }
        }
        return out
    }
}
