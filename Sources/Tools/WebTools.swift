//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// WebTools.swift
//

import Foundation
import Stores

public enum WebTools {
    
    // MARK: - Tool Definitions for OpenAI / MLX Schema
    
    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            function: FunctionDefinition(
                name: "web_fetch",
                description: "Fetches and converts the text content of any HTTP/HTTPS URL into readable plain text.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "url": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The target HTTP/HTTPS URL to read")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("url")])
                ]
            )
        ),
        ToolDefinition(
            function: FunctionDefinition(
                name: "web_search",
                description: "Searches the live web for real-time information, Swift documentation, or code solutions.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "query": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The web search query string")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("query")])
                ]
            )
        )
    ]
    
    // MARK: - Execution Dispatcher
    
    public static func execute(name: String, argsJSON: String) async -> String {
        guard let data = argsJSON.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "Error: Invalid JSON parameters supplied to \(name)"
        }
        
        switch name {
        case "web_fetch":
            guard let urlString = args["url"] as? String else { return "Error: Missing 'url' parameter" }
            return await fetchURL(urlString)
            
        case "web_search":
            guard let query = args["query"] as? String else { return "Error: Missing 'query' parameter" }
            return await searchWeb(query)
            
        default:
            return "Error: Unknown tool '\(name)'"
        }
    }
    
    // MARK: - Core Web Implementations
    
    /// Fetches HTML from a web page and strips tags/scripts into plain text
    private static func fetchURL(_ urlString: String) async -> String {
        guard let url = URL(string: urlString) else {
            return "Error: Invalid URL string '\(urlString)'"
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 15.0
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return "Error: Server returned non-200 HTTP status."
            }
            
            guard let htmlString = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                return "Error: Failed to decode web page data."
            }
            
            return cleanHTML(htmlString)
        } catch {
            return "Error fetching URL: \(error.localizedDescription)"
        }
    }
    
    /// Executes web search using Tavily API (or falls back to DuckDuckGo HTML)
    private static func searchWeb(_ query: String) async -> String {
        // Option A: Tavily API Search (If API key exists in environment)
        if let apiKey = ProcessInfo.processInfo.environment["TAVILY_API_KEY"], !apiKey.isEmpty {
            return await searchTavily(query: query, apiKey: apiKey)
        }
        
        // Option B: DuckDuckGo Fallback
        return await searchDuckDuckGo(query: query)
    }
    
    private static func searchTavily(query: String, apiKey: String) async -> String {
        guard let url = URL(string: "https://api.tavily.com/search") else { return "Error creating search URL" }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            "api_key": apiKey,
            "query": query,
            "max_results": 5
        ]
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else { return "Error serializing request" }
        request.httpBody = httpBody
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return "No results found."
            }
            
            return results.compactMap { dict in
                guard let title = dict["title"] as? String,
                      let link = dict["url"] as? String,
                      let content = dict["content"] as? String else { return nil }
                return "### \(title)\nURL: \(link)\n\(content)\n"
            }.joined(separator: "\n---\n")
        } catch {
            return "Search error: \(error.localizedDescription)"
        }
    }
    
    private static func searchDuckDuckGo(query: String) async -> String {
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encodedQuery)") else {
            return "Error constructing query URL."
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { return "Failed to read search response." }
            let text = cleanHTML(html)
            return String(text.prefix(3000)) // Cap response size
        } catch {
            return "Search failed: \(error.localizedDescription)"
        }
    }
    
    // Helper to strip CSS, JavaScript, and HTML tags into clean text
    private static func cleanHTML(_ html: String) -> String {
        var text = html
        // 1. Remove script & style tags
        text = text.replacingOccurrences(of: "(?s)<script.*?>.*?</script>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?s)<style.*?>.*?</style>", with: "", options: .regularExpression)
        // 2. Strip standard HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
        // 3. Clean up blank space & newlines
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n").prefix(4000).description
    }
}
