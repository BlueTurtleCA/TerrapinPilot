//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ContextResolver.swift
//

import Foundation
import Stores

public struct ContextManager {

    /// Estimates token count for a message list (approx. 1 token = 3.5 characters)
    private static func estimateTokenCount(_ history: [ChatMessage]) -> Int {
        var totalChars = 0
        for msg in history {
            totalChars += msg.content?.count ?? 0
            totalChars += msg.reasoning?.count ?? 0
            if let toolCalls = msg.toolCalls {
                for call in toolCalls {
                    totalChars +=
                        call.function.name.count + call.function.arguments.count
                }
            }
        }
        return Int(Double(totalChars) / 3.5)
    }

    /// Safely truncates middle messages when token limit is approached
    public static func compactHistory(
        _ history: [ChatMessage],
        maxTokens: Int = 16384,  // Set to your model's context size (e.g. 8192, 16384, 32768)
        targetBudgetRatio: Double = 0.90  // Compact when usage exceeds 90% of max context
    ) -> [ChatMessage] {
        let currentTokens = estimateTokenCount(history)
        let tokenLimit = Int(Double(maxTokens) * targetBudgetRatio)

        // Return untouched if within context budget
        guard currentTokens > tokenLimit, history.count > 4 else {
            return history
        }

        let systemMessage = history.first { $0.role == "system" }
        var compacted: [ChatMessage] = []

        if let systemMessage {
            compacted.append(systemMessage)
        }

        // Add a compaction notice marker
        compacted.append(
            ChatMessage(
                role: "user",
                content:
                    "System Note: Older conversation turns were compacted to stay within the context window limit."
            )
        )
        compacted.append(
            ChatMessage(
                role: "assistant",
                content:
                    "Understood. I will continue focusing on your latest commands using the existing workspace state."
            )
        )

        // Keep the most recent messages that fit within a token budget, so a
        // single huge tool result can't blow the window and small turns keep
        // more context than a fixed message count would allow.
        let keepBudget = Int(Double(maxTokens) * 0.50)
        var recentMessages: [ChatMessage] = []
        var usedTokens = 0
        for message in history.reversed() {
            let messageTokens = estimateTokenCount([message])
            if !recentMessages.isEmpty, usedTokens + messageTokens > keepBudget {
                break
            }
            recentMessages.insert(message, at: 0)
            usedTokens += messageTokens
        }

        // Ensure we don't start recent history with an orphaned tool response
        while let first = recentMessages.first, first.role == "tool" {
            recentMessages.removeFirst()
        }

        compacted.append(contentsOf: recentMessages)
        return compacted
    }

    /// Queries the AI server's endpoints to retrieve the loaded model's context window
    public static func resolveContextWindow(
        _ endpoint: String
    ) async -> Int {
        let candidateURLs = [
            "\(endpoint)/api/v1/models",
            "\(endpoint)/v1/models",
        ].compactMap { URL(string: $0) }

        for url in candidateURLs {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                let json = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let models = json["data"] as? [[String: Any]],
                let activeModel = models.first(where: {
                    ($0["state"] as? String) == "loaded"
                }) ?? models.first
            else {
                continue
            }

            // llama.cpp reports the context length inside a "meta" object, and
            // the exact key varies by version:
            //   new: data[0].meta.n_ctx
            //   old: data[0].meta.model_info.context_length
            // Check "meta" first so we don't silently fall back to 16384 (which
            // would make compaction fire every turn and destroy KV prefix reuse).
            if let meta = activeModel["meta"] as? [String: Any] {
                if let ctxLen = meta["n_ctx"] as? Int {
                    return ctxLen
                }
                if let modelInfo = meta["model_info"] as? [String: Any],
                    let ctxLen = modelInfo["context_length"] as? Int
                {
                    return ctxLen
                }
                if let ctxLen = meta["context_length"] as? Int {
                    return ctxLen
                }
            }

            // 1. Check direct server property
            if let maxCtx = activeModel["max_context_length"] as? Int {
                return maxCtx
            }

            // 2. Some servers expose model_info at the top level
            if let modelInfo = activeModel["model_info"] as? [String: Any],
                let ctxLen = modelInfo["context_length"] as? Int
            {
                return ctxLen
            }

            // 3. Check active instance config (v1 REST API)
            if let instances = activeModel["loaded_instances"]
                as? [[String: Any]],
                let config = instances.first?["config"] as? [String: Any],
                let ctxLen = config["context_length"] as? Int
            {
                return ctxLen
            }

            // 4. Check standard fallback property
            if let ctxLen = activeModel["context_length"] as? Int {
                return ctxLen
            }
        }

        // Conservative fallback if metadata is unavailable
        return 16384
    }
}
