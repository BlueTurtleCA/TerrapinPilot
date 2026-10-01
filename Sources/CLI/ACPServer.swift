//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ACPServer.swift
//

import Agent
import Foundation
import Logger
import Stores
import Tools

/// ACP (Agent Client Protocol) server: reads JSON-RPC messages from stdin,
/// dispatches them to the agent, and writes JSON-RPC responses to stdout.
final class ACPServer: Sendable {
    private let agent: Agent
    private let sessionStore: SessionStore
    private let tools: [ToolDefinition]
    private let logger: Loggable
    private let stdoutLock = NSLock()

    init(
        agent: Agent,
        sessionStore: SessionStore,
        tools: [ToolDefinition],
        logger: Loggable
    ) {
        self.agent = agent
        self.sessionStore = sessionStore
        self.tools = tools
        self.logger = logger
    }

    /// Runs the stdin read/parse/dispatch loop until stdin closes.
    func run() async {
        while let line = readLine() {
            await handle(line)
        }
    }

    // MARK: - Dispatch

    private func handle(_ line: String) async {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        logger.debug("IN  <--- \(line)")

        guard let data = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return }

        let method = json["method"] as? String ?? ""
        let hasId = json.keys.contains("id") && !(json["id"] is NSNull)
        // Safely parses String OR Int IDs into a Sendable String?
        let reqId: String? =
            (json["id"] as? String) ?? (json["id"] as? Int).map(String.init)

        switch method {
        case "initialize":
            handleInitialize(hasId: hasId, reqId: reqId)
        case "session/new":
            await handleNewSession(json: json, hasId: hasId, reqId: reqId)
        case "session/prompt":
            await handlePrompt(json: json, hasId: hasId, reqId: reqId)
        case "session/cancel":
            handleCancel(hasId: hasId, reqId: reqId)
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

    private func handleInitialize(hasId: Bool, reqId: String?) {
        guard hasId, let reqId else { return }
        sendJSON([
            "jsonrpc": "2.0",
            "id": reqId,
            "result": [
                "protocolVersion": 1,
                "agentCapabilities": ["loadSession": false],
                "agentInfo": ["name": "TerrapinPilot", "version": "1.0.0"],
                "authMethods": [],
            ],
        ])
    }

    private func handleNewSession(
        json: [String: Any],
        hasId: Bool,
        reqId: String?
    ) async {
        guard hasId, let reqId else { return }
        let params = json["params"] as? [String: Any]
        let cwd = Self.extractParam(params, key: "cwd")
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

    private func handlePrompt(
        json: [String: Any],
        hasId: Bool,
        reqId: String?
    ) async {
        guard hasId, let reqId else { return }
        let params = json["params"] as? [String: Any]
        let sessionId = params?["sessionId"] as? String ?? ""
        let userPrompt = Self.extractParam(params, key: "prompt")

        // Resolve working directory (fallback to standard user home directory)
        let cwd =
            await sessionStore.getCWD(for: sessionId)
            ?? Self.extractParam(params, key: "cwd")

        Task.detached {
            await self.agent.run(
                prompt: userPrompt,
                sessionId: sessionId,
                cwd: cwd,
                tools: self.tools,
                onChunk: { text in
                    self.sendChunk(sessionId: sessionId, text: text)
                },
                onThought: { text in
                    self.sendThoughtChunk(sessionId: sessionId, text: text)
                }
            )

            // Complete the ACP prompt request
            self.sendJSON([
                "jsonrpc": "2.0",
                "id": reqId,
                "result": [
                    "stopReason": "end_turn"
                ],
            ])
        }
    }

    private func handleCancel(hasId: Bool, reqId: String?) {
        guard hasId, let reqId else { return }
        sendJSON([
            "jsonrpc": "2.0",
            "id": reqId,
            "result": ["stopReason": "cancelled"],
        ])
    }

    // MARK: - Output

    private func sendJSON(_ dictionary: [String: Any]) {
        stdoutLock.lock()
        defer { stdoutLock.unlock() }

        guard let data = try? JSONSerialization.data(withJSONObject: dictionary),
            let jsonString = String(data: data, encoding: .utf8)
        else { return }
        logger.debug("OUT ---> \(jsonString)")
        print(jsonString)
        fflush(stdout)
    }

    private func sendChunk(sessionId: String, text: String) {
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

    private func sendThoughtChunk(sessionId: String, text: String) {
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "agent_thought_chunk",
                    "content": [
                        "type": "text",
                        "text": text,
                    ],
                ],
            ],
        ])
    }

    // MARK: - Helpers

    /// Extracts a prompt string or path parameter from ACP params.
    private static func extractParam(_ params: [String: Any]?, key: String) -> String {
        guard let params = params else { return "" }
        if let str = params[key] as? String { return str }
        if let blocks = params[key] as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(
                separator: "\n"
            )
        }
        return ""
    }
}
