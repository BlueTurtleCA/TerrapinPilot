//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// Agent.swift
//

import Foundation
import Helpers
import Logger
import Stores
import Tools

/// Drives the agentic execution loop: prompt the model, dispatch tool calls,
/// and repeat until the model produces a final answer.
public struct Agent: Sendable {
    private let llmClient: LLMClient
    private let toolRegistry: ToolRegistry
    private let sessionStore: SessionStore
    private let contextWindow: Int
    private let systemPromptTemplate: String
    private let logger: Loggable
    private let slotCount: Int

    public init(
        llmClient: LLMClient,
        toolRegistry: ToolRegistry,
        sessionStore: SessionStore,
        contextWindow: Int,
        systemPromptTemplate: String,
        logger: Loggable,
        slotCount: Int = 1
    ) {
        self.llmClient = llmClient
        self.toolRegistry = toolRegistry
        self.sessionStore = sessionStore
        self.contextWindow = contextWindow
        self.systemPromptTemplate = systemPromptTemplate
        self.logger = logger
        self.slotCount = slotCount
    }

    /// Runs a full agent turn for `prompt` within `sessionId`.
    public func run(
        prompt: String,
        sessionId: String,
        cwd: String,
        tools: [ToolDefinition],
        onChunk: @escaping @Sendable (String) -> Void,
        onThought: @escaping @Sendable (String) -> Void
    ) async {
        var history = await sessionStore.getHistory(
            for: sessionId,
            defaultSystemPrompt: buildSystemPrompt(cwd: cwd)
        )
        history.append(ChatMessage(role: "user", content: prompt))

        // Pin this session to a stable server slot so the backend (llama.cpp)
        // can reuse its KV cache across turns and only process the delta.
        let slotId = Self.slotId(for: sessionId, count: slotCount)

        // Open the Xcode workspace up front so workspace tools work on the
        // first call and the user's access approval is requested immediately.
        await toolRegistry.prepare(cwd: cwd)

        let maxTurns = 50
        var currentTurn = 0

        while currentTurn < maxTurns {
            currentTurn += 1

            // Compact history if approaching context window limit
            history = ContextManager.compactHistory(history, maxTokens: contextWindow)

            let response: LLMResponse
            do {
                response = try await llmClient.complete(
                    messages: history,
                    tools: tools,
                    slotId: slotId,
                    onContent: { text in
                        onChunk(text)
                    },
                    onThought: { text in
                        onThought(text)
                    }
                )
            } catch LLMError.httpStatus(let code, let body) {
                logger.debug("AI Server \(code) Error Response: \(body)")
                onChunk("⚠️ Error connecting to local AI server.")
                break
            } catch LLMError.streamInterrupted {
                onChunk("⚠️ Connection to AI server dropped mid-response.")
                break
            } catch LLMError.badResponse {
                onChunk("⚠️ Failed to parse response from AI server.")
                break
            } catch {
                onChunk("⚠️ Error during agent turn: \(error.localizedDescription)")
                break
            }

            // Check if model emitted tool calls
            if !response.toolCalls.isEmpty {
                // Record the assistant's tool_calls message in history FIRST,
                // including any reasoning so the prefix stays stable for reuse.
                history.append(
                    ChatMessage(
                        role: "assistant",
                        reasoning: response.reasoning,
                        toolCalls: response.toolCalls
                    )
                )

                // Execute tools and append results back to chat history
                for call in response.toolCalls {
                    onChunk(
                        "\n\n🛠️ *Executing Tool:* `\(call.function.name)`...\n\n"
                    )

                    let result = await toolRegistry.execute(
                        name: call.function.name,
                        argsJSON: call.function.arguments,
                        cwd: cwd
                    )
                    history.append(
                        ChatMessage(
                            role: "tool",
                            content: result,
                            toolCallId: call.id,
                            name: call.function.name
                        )
                    )
                }

                // Loop back to send tool results to the AI server
                continue
            }

            // Final text response from LLM (already streamed via onContent)
            if let content = response.content, !content.isEmpty {
                history.append(
                    ChatMessage(
                        role: "assistant",
                        content: content,
                        reasoning: response.reasoning
                    )
                )
            }

            break
        }

        // Save updated history
        await sessionStore.saveHistory(history, for: sessionId)
    }

    // MARK: - Prompt Building

    private func buildSystemPrompt(cwd: String) -> String {
        var customInstructionsBlock = ""

        if let agentInstructions = loadWorkspaceInstructions(from: cwd) {
            customInstructionsBlock = """

                ### PROJECT-SPECIFIC INSTRUCTIONS (AGENTS.MD)
                \(agentInstructions)
                """
        }

        return systemPromptTemplate
            .replacingOccurrences(of: "{{CWD}}", with: cwd)
            .replacingOccurrences(of: "{{CUSTOM_INSTRUCTIONS}}", with: customInstructionsBlock)
    }

    // MARK: - Slot Mapping

    /// Maps a session to a stable server slot in `0..<count` using FNV-1a, so
    /// the same session always hits the same slot (and its cached context)
    /// across turns and process restarts. Returns `nil` when no slots are
    /// configured, letting the server pick one.
    private static func slotId(for sessionId: String, count: Int) -> Int? {
        guard count >= 1 else { return nil }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in sessionId.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % UInt64(count))
    }
}

// MARK: - Workspace Instructions

/// Loads project-specific instructions from an AGENTS.md file in `cwd`.
func loadWorkspaceInstructions(from cwd: String) -> String? {
    // Find the instructions file case-insensitively (agents.md, AGENTS.md, aGents.md, ...)
    guard let agentFileURL = findFile(named: "agents", extension: "md", in: cwd),
        let contents = try? String(contentsOf: agentFileURL, encoding: .utf8),
        !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        return nil
    }

    return contents.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Resolves a file in `directory` whose name and extension match case-insensitively.
func findFile(
    named name: String,
    extension ext: String,
    in directory: String
) -> URL? {
    let dirURL = URL(filePath: directory)
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }

    for entry in entries {
        // Compare the name and extension parts separately so that any casing works,
        // while still excluding directories that happen to share the file's name.
        let fileName = (entry as NSString).deletingPathExtension.lowercased()
        let fileExt = (entry as NSString).pathExtension.lowercased()
        guard fileName == name.lowercased(), fileExt == ext.lowercased() else { continue }

        let url = dirURL.appendingPathComponent(entry)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        {
            return url
        }
    }
    return nil
}
