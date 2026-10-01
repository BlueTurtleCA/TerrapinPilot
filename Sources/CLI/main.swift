//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// main.swift
//

import Agent
import Enums
import Foundation
import Helpers
import Logger
import Stores
import Tools

// 1. Load runtime configuration (CLI args / env vars)
let config = Config.load()

let logger = OSLogger()
let sessionStore = SessionStore()

// 2. Initialize and start the native Xcode MCP bridge client
let mcpClient = XcodeMCPBridgeClient(logger)
do {
    try await mcpClient.start()
} catch {
    throw MCPError.failedToInitialize(error)
}

// 3. Register all tool providers (Xcode MCP tools + built-in web tools)
await mcpClient.fetchTools()
let toolRegistry = ToolRegistry([mcpClient, WebTools()])
let allTools = await toolRegistry.definitions()

let contextWindow: Int
if let override = config.contextWindowOverride {
    contextWindow = override
} else {
    contextWindow = await ContextManager.resolveContextWindow(
        config.serverURL.absoluteString
    )
}
logger.debug("Using context window of: \(contextWindow)")
if config.debugLog {
    logger.debug("Debug logging enabled: request bodies -> /tmp/terrapinpilot-llm/")
}

// 4. Wire up the agent
let agent = Agent(
    llmClient: OpenAICompatibleClient(
        endpoint: config.chatCompletionsURL,
        model: config.model,
        debugLog: config.debugLog
    ),
    toolRegistry: toolRegistry,
    sessionStore: sessionStore,
    contextWindow: contextWindow,
    systemPromptTemplate: loadSystemPromptTemplate(),
    logger: logger,
    slotCount: config.slots
)

// 5. Serve ACP over stdin/stdout
let server = ACPServer(
    agent: agent,
    sessionStore: sessionStore,
    tools: allTools,
    logger: logger
)
logger.debug("=== Swift ACP Agent Started with Tool Calling ===")
await server.run()

// MARK: - System Prompt Template

/// Loads the bundled system prompt template from the compiled resources.
func loadSystemPromptTemplate() -> String {
    guard
        let url = Bundle.module.url(forResource: "system_prompt", withExtension: "txt"),
        let contents = try? String(contentsOf: url, encoding: .utf8)
    else {
        fatalError("Failed to load bundled system prompt template")
    }
    return contents
}
