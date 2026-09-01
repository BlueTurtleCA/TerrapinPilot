//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// Main.swift
//

import Enums
import Foundation
import Helpers
import Logger
import Stores
import Tools
import os

// Configurable MLX / OpenAI endpoint
let mlxHost = "http://localhost:8080"
let mlxEndpoint = "\(mlxHost)/v1/chat/completions"

// Native macOS Logger & thread lock
let stdoutLock = NSLock()

// Session state storage
let sessionStore = SessionStore()
let logger = OSLogger()

// 1. Initialize and start the native Xcode MCP bridge client
let mcpClient = XcodeMCPBridgeClient(logger)
do {
    try await mcpClient.start()
} catch {
    throw MCPError.failedToInitialize(error)
}

// 2. Fetch available tools directly from Xcode
let xcodeTools = await mcpClient.fetchTools()
let allTools = xcodeTools + WebTools.definitions

let contextWindow = await ContextManager.resolveContextWindow(mlxHost)
logger.debug("Using context window of: \(contextWindow)")

// Configure session timeouts at the top of your agent or worker service
private let llmSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 10 * 60.0  // 10 minutes per request/token packet
    config.timeoutIntervalForResource = 4 * config.timeoutIntervalForRequest  // 4x minutes max for the entire stream/turn
    return URLSession(configuration: config)
}()

func sendJSON(_ dictionary: [String: Any]) {
    stdoutLock.lock()
    defer { stdoutLock.unlock() }

    guard let data = try? JSONSerialization.data(withJSONObject: dictionary),
        let jsonString = String(data: data, encoding: .utf8)
    else { return }
    logger.debug("OUT ---> \(jsonString)")
    print(jsonString)
    fflush(stdout)
}

func sendChunk(sessionId: String, text: String) {
    sendJSON([
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": [
            "sessionId": sessionId,
            "update": [
                "sessionUpdate": "agent_message_chunk",
                "content": [
                    "type": "text",
                    "text": text,
                ],
            ],
        ],
    ])
}

public func loadWorkspaceInstructions(from cwd: String) -> String? {
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

// MARK: - Agentic Execution Loop
func runAgentLoop(prompt: String, sessionId: String, reqId: Any, cwd: String)
    async
{
    guard let url = URL(string: mlxEndpoint) else { return }

    var customInstructionsBlock = ""

    if let agentInstructions = loadWorkspaceInstructions(from: cwd) {
        customInstructionsBlock = """
               
            ### PROJECT-SPECIFIC INSTRUCTIONS (AGENTS.MD)
            \(agentInstructions)
            """
    }

    // Initialize or append to session history
    let systemPrompt = """
        You are an expert Apple platforms developer and Senior Swift Engineer integrated directly into Xcode via the Agent Client Protocol (ACP) and Model Context Protocol (MCP).

        ### ENVIRONMENT & WORKSPACE
        - You operate within the user's active Xcode workspace directory: \(cwd)

        ### TOOL CALLING GUIDELINES
        - Use native Xcode MCP tools to inspect files, build projects, run tests, and debug code.
        - Read before writing: Always inspect existing file contents or project definitions before attempting modifications.
        - Output complete, production-ready source code when making file modifications. Never use placeholder comments like `// rest of code here...`.

        ### WEB & INTERNET CAPABILITIES
        - You have live internet access via `web_search` and `web_fetch`.
        - Use `web_search` to find up-to-date Apple documentation, third-party library specs, recent Swift package releases, or obscure compiler error solutions.
        - Use `web_fetch` to read full documentation pages, GitHub READMEs, or web articles.
        - Do NOT search the web for files inside the project workspace—use local Xcode/file tools first.

        ### BUILD & DIAGNOSTIC RULES
        - After making code changes, verify your work using `BuildProject` when available. VERY IMPORTANT TO DO THIS SO THAT WE CATCH ERRORS EARLY.
        - If a build fails, inspect `GetBuildLog` or diagnostic errors before proposing a fix.

        ### SWIFT 6 CONCURRENCY RIGOR
        - Default to Swift 6, `@Observable`, and modern `async/await` concurrency.
        - Mark UI-bound types with `@MainActor` and ensure cross-actor data conforms to `Sendable`.
        - Prefer structured concurrency (`async let`, `TaskGroup`) over unstructured `Task { }`.

        ### RESPONSE FORMATTING
        - Be concise and direct without conversational fluff.
        - Always label code blocks with their relative file path (e.g., `// File: Sources/CLI/main.swift`).
        \(customInstructionsBlock)
        """

    let encoder = JSONEncoder()

    // Initialize chat history with the system prompt
    var history = await sessionStore.getHistory(
        for: sessionId,
        defaultSystemPrompt: systemPrompt
    )
    history.append(ChatMessage(role: "user", content: prompt))

    let maxTurns = 50
    var currentTurn = 0

    while currentTurn < maxTurns {
        currentTurn += 1

        // Compact history if approaching context window limit (e.g. 16k tokens)
        history = ContextManager.compactHistory(history, maxTokens: contextWindow)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let historyData = try? encoder.encode(history),
            let historyJSONObject = try? JSONSerialization.jsonObject(
                with: historyData
            )
        else {
            logger.debug(
                "ERROR: Failed to convert history [ChatMessage] to JSON object"
            )
            break
        }

        guard let toolsData = try? encoder.encode(allTools),
            let toolsJSONObject = try? JSONSerialization.jsonObject(
                with: toolsData
            )
        else {
            logger.debug("ERROR: Failed to encode active MCP tools into JSON")
            break
        }

        let payload: [String: Any] = [
            "model": "default",
            "messages": historyJSONObject,
            "tools": toolsJSONObject,
            "tool_choice": "auto",
        ]

        guard
            let httpBody = try? JSONSerialization.data(withJSONObject: payload)
        else { break }
        request.httpBody = httpBody

        do {
            let (data, response) = try await llmSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                (200...299).contains(httpResponse.statusCode)
            else {
                // 💡 Print the exact validation error returned by the server
                if let errorText = String(data: data, encoding: .utf8) {
                    logger.debug("MLX Server 400 Error Response: \(errorText)")
                }
                sendChunk(
                    sessionId: sessionId,
                    text: "⚠️ Error connecting to local MLX server."
                )
                break
            }

            guard
                let json = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let firstChoice = choices.first,
                let message = firstChoice["message"] as? [String: Any]
            else {
                sendChunk(
                    sessionId: sessionId,
                    text: "⚠️ Failed to parse response from MLX."
                )
                break
            }

            // Check if model emitted tool calls
            if let toolCallsDicts = message["tool_calls"] as? [[String: Any]],
                !toolCallsDicts.isEmpty
            {

                // 1. Convert raw dictionaries into typed, Sendable [ToolCall]
                var parsedToolCalls: [ToolCall] = []
                for call in toolCallsDicts {
                    if let callId = call["id"] as? String,
                        let function = call["function"] as? [String: Any],
                        let toolName = function["name"] as? String,
                        let argsString = function["arguments"] as? String
                    {
                        parsedToolCalls.append(
                            ToolCall(
                                id: callId,
                                function: FunctionCall(
                                    name: toolName,
                                    arguments: argsString
                                )
                            )
                        )
                    }
                }

                // 2. Record the assistant's tool_calls message in history FIRST
                history.append(
                    ChatMessage(role: "assistant", toolCalls: parsedToolCalls)
                )

                // 3. Execute tools via Xcode mcpbridge and append results
                for call in parsedToolCalls {
                    let callId = call.id
                    let toolName = call.function.name
                    let argsString = call.function.arguments

                    // Display UI progress indicator in Xcode Chat
                    sendChunk(
                        sessionId: sessionId,
                        text: "\n\n🛠️ *Executing Tool:* `\(toolName)`...\n\n"
                    )

                    // Append tool result message back to chat history
                    if WebTools.definitions.contains(where: {
                        $0.function.name == toolName
                    }) {
                        let webResult = await WebTools.execute(
                            name: toolName,
                            argsJSON: argsString
                        )
                        history.append(
                            ChatMessage(
                                role: "tool",
                                content: webResult,
                                toolCallId: callId,
                                name: toolName
                            )
                        )
                    } else {
                        let xcodeResult = await mcpClient.callTool(
                            name: toolName,
                            argsJSON: argsString,
                            cwd: cwd
                        )
                        history.append(
                            ChatMessage(
                                role: "tool",
                                content: xcodeResult,
                                toolCallId: callId,
                                name: toolName
                            )
                        )
                    }
                }

                // Loop back to send tool results back to MLX
                continue
            }

            // Final text response from LLM
            if let content = message["content"] as? String, !content.isEmpty {
                sendChunk(sessionId: sessionId, text: content)
                history.append(ChatMessage(role: "assistant", content: content))
            }

            break

        } catch {
            sendChunk(
                sessionId: sessionId,
                text: "⚠️ Error during agent turn: \(error.localizedDescription)"
            )
            break
        }
    }

    // Save updated history
    await sessionStore.saveHistory(history, for: sessionId)

    // Complete the ACP prompt request
    sendJSON([
        "jsonrpc": "2.0",
        "id": reqId,
        "result": [
            "stopReason": "end_turn"
        ],
    ])
}

// Helper to extract prompt string or path parameter
func extractParam(_ params: [String: Any]?, key: String) -> String {
    guard let params = params else { return "" }
    if let str = params[key] as? String { return str }
    if let blocks = params[key] as? [[String: Any]] {
        return blocks.compactMap { $0["text"] as? String }.joined(
            separator: "\n"
        )
    }
    return ""
}

// MARK: - MAIN EXECUTION LOOP

logger.debug("=== Swift ACP Agent Started with Tool Calling ===")

while let line = readLine() {
    guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        continue
    }
    logger.debug("IN  <--- \(line)")

    guard let data = line.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
    else { continue }

    let method = json["method"] as? String ?? ""
    let hasId = json.keys.contains("id") && !(json["id"] is NSNull)
    // Safely parses String OR Int IDs into a Sendable String?
    let reqId: String? =
        (json["id"] as? String) ?? (json["id"] as? Int).map(String.init)

    switch method {
    case "initialize":
        if hasId, let reqId {
            sendJSON([
                "jsonrpc": "2.0",
                "id": reqId,
                "result": [
                    "protocolVersion": 1,
                    "agentCapabilities": ["loadSession": false],
                    "agentInfo": ["name": "blueacp", "version": "1.0.0"],
                    "authMethods": [],
                ],
            ])
        }

    case "session/new":
        if hasId, let reqId {
            let params = json["params"] as? [String: Any]
            let cwd = extractParam(params, key: "cwd")
            let newSessionId = UUID().uuidString

            if !cwd.isEmpty {
                await sessionStore.setCWD(cwd, for: newSessionId)
            }

            sendJSON([
                "jsonrpc": "2.0",
                "id": reqId,
                "result": ["sessionId": newSessionId],
            ])
        }

    case "session/prompt":
        guard hasId, let reqId else { continue }
        let params = json["params"] as? [String: Any]
        let sessionId = params?["sessionId"] as? String ?? ""
        let userPrompt = extractParam(params, key: "prompt")

        // Resolve working directory (fallback to standard user home directory)
        let cwd =
            await sessionStore.getCWD(for: sessionId)
            ?? extractParam(params, key: "cwd")
        Task.detached {
            await runAgentLoop(
                prompt: userPrompt,
                sessionId: sessionId,
                reqId: reqId,
                cwd: cwd
            )
        }

    case "session/cancel":
        if hasId, let reqId {
            sendJSON([
                "jsonrpc": "2.0",
                "id": reqId,
                "result": ["stopReason": "cancelled"],
            ])
        }

    default:
        if hasId, let reqId {
            sendJSON([
                "jsonrpc": "2.0",
                "id": reqId,
                "result": [:],
            ])
        }
    }
}
