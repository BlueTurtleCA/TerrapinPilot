//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// main.swift
//

import Agent
import Foundation
import Helpers
import Logger
import Stores
import Tools

// 1. Load runtime configuration (CLI args / env vars)
let config = Config.load()

let logger = OSLogger()
let sessionStore = SessionStore()

// 2. Create the native Xcode MCP bridge client. It is started lazily by the
//    ACP server once the connecting client identifies itself as Xcode.
let mcpClient = XcodeMCPBridgeClient(logger)

// 3. Register the client-agnostic tool providers (built-in web tools +
//    native ACP client tools). The Xcode MCP bridge is added to the registry
//    by the ACP server after client detection.
let clientChannel = ClientChannel()
let clientTools = ACPWrapperTools(clientChannel: clientChannel)
let toolRegistry = ToolRegistry([WebTools(), clientTools])
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
    systemPromptTemplates: loadSystemPromptTemplates(),
    logger: logger,
    slotCount: config.slots
)

// 5. Serve ACP over stdin/stdout
let server = ACPServer(
    agent: agent,
    sessionStore: sessionStore,
    tools: allTools,
    toolRegistry: toolRegistry,
    xcodeBridge: mcpClient,
    clientChannel: clientChannel,
    clientTools: clientTools,
    defaultClient: config.defaultClient,
    logger: logger
)
logger.debug("=== Swift ACP Agent Started with Tool Calling ===")
await server.run()

// MARK: - System Prompt Templates

/// Loads the bundled system prompt templates (one per client kind) from the
/// compiled resources.
func loadSystemPromptTemplates() -> [ClientKind: String] {
    func load(_ name: String) -> String {
        guard
            let url = Bundle.module.url(forResource: name, withExtension: "txt"),
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            fatalError("Failed to load bundled system prompt template \(name).txt")
        }
        return contents
    }
    return [
        .xcode: load("system_prompt_xcode"),
        .generic(name: "unknown"): load("system_prompt_generic"),
    ]
}
