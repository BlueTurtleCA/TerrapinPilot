//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// XcodeMCPBridgeClient.swift
//

import Foundation
import Logger
import Stores

public actor XcodeMCPBridgeClient {
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var buffer = Data()
    private var logger: Loggable

    private var activeTabIdentifier: String?

    public init(_ logger: Loggable) {
        self.logger = logger
    }

    /// Spawns `xcrun mcpbridge` using environment variables passed by Xcode ACP
    public func start(env: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = ["mcpbridge"]

        // 1. Inject Xcode PID and Session ID into process environment
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env {
            environment[key] = value
        }
        process.environment = environment

        let inPipe = Pipe()
        let outPipe = Pipe()

        process.standardInput = inPipe
        process.standardOutput = outPipe

        self.inputPipe = inPipe
        self.outputPipe = outPipe
        self.process = process

        try process.run()

        // 2. Step 1 of MCP Handshake: Send initialize request
        let initRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "blueacp", "version": "1.0.0"],
            ],
        ]
        _ = try? sendRPC(initRequest)

        // 3. Step 2 of MCP Handshake: Send mandatory notifications/initialized
        let initializedNotification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        try? sendNotification(initializedNotification)
    }

    /// Fetches all dynamic workspace tools provided by Xcode's mcpbridge
    public func fetchTools() async -> [ToolDefinition] {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        ]

        guard let response = try? sendRPC(request),
            let result = response["result"] as? [String: Any],
            let toolsArray = result["tools"] as? [[String: Any]]
        else {
            return []
        }

        var tools: [ToolDefinition] = []
        for toolDict in toolsArray {
            guard let name = toolDict["name"] as? String,
                let description = toolDict["description"] as? String,
                let inputSchema = toolDict["inputSchema"] as? [String: Any]
            else { continue }

            if let schemaData = try? JSONSerialization.data(
                withJSONObject: inputSchema
            ),
                let wrappedSchema = try? JSONDecoder().decode(
                    [String: AnySendable].self,
                    from: schemaData
                )
            {

                let definition = ToolDefinition(
                    function: FunctionDefinition(
                        name: name,
                        description: description,
                        parameters: wrappedSchema
                    )
                )
                tools.append(definition)
            }
        }

        return tools
    }

    /// Executes a tool call in Xcode via mcpbridge, with automatic tabIdentifier injection
    public func callTool(name: String, argsJSON: String, cwd: String)
        async -> String
    {
        let argsData = argsJSON.data(using: .utf8) ?? Data()
        var argsDict =
            (try? JSONSerialization.jsonObject(with: argsData) as? [String: Any])
            ?? [:]

        // 1. Auto-inject cached tabIdentifier if available and missing from LLM arguments
        if argsDict["tabIdentifier"] == nil, let cachedTab = activeTabIdentifier
        {
            argsDict["tabIdentifier"] = cachedTab
        }

        // Send initial RPC tool call request
        let response = sendToolRPC(name: name, argsDict: argsDict)
        let outputText = parseToolOutput(response: response, name: name)

        // 2. Check if mcpbridge threw a tabIdentifier required error
        if outputText.contains("tabIdentifier is required for this action") {
            if let matchedTab = parseTabIdentifier(
                from: outputText,
                matchingCWD: cwd
            ) {
                // Cache the matched tab for future calls
                self.activeTabIdentifier = matchedTab

                // Re-inject tabIdentifier and retry immediately
                argsDict["tabIdentifier"] = matchedTab
                let retryResponse = sendToolRPC(name: name, argsDict: argsDict)
                return parseToolOutput(response: retryResponse, name: name)
            }
        }

        return outputText
    }

    // MARK: - Helper Methods

    private func sendToolRPC(name: String, argsDict: [String: Any]) -> [String:
        Any]?
    {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 1000...9999),
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": argsDict,
            ],
        ]
        return try? sendRPC(request)
    }

    private func parseToolOutput(response: [String: Any]?, name: String)
        -> String
    {
        guard let response else {
            return "Error: No response from Xcode mcpbridge"
        }

        if let error = response["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            return "Error executing tool '\(name)': \(message)"
        }

        guard let result = response["result"] as? [String: Any],
            let content = result["content"] as? [[String: Any]]
        else {
            return "Error: Invalid content returned by tool '\(name)'"
        }

        let lines = content.compactMap { $0["text"] as? String }
        return lines.joined(separator: "\n")
    }

    /// Matches open window tabs directly against the pre-normalized `cwd`
    private func parseTabIdentifier(from errorText: String, matchingCWD: String)
        -> String?
    {
        let lines = errorText.components(separatedBy: .newlines)
        var matches: [(tab: String, path: String)] = []

        for line in lines
        where line.contains("tabIdentifier:") && line.contains("workspacePath:")
        {
            let parts = line.components(separatedBy: ",")
            var foundTab = ""
            var foundPath = ""

            for part in parts {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("tabIdentifier:") {
                    foundTab = trimmed.replacingOccurrences(of: "*", with: "")
                        .replacingOccurrences(of: "tabIdentifier:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                } else if trimmed.contains("workspacePath:") {
                    foundPath = trimmed.replacingOccurrences(
                        of: "workspacePath:",
                        with: ""
                    )
                    .trimmingCharacters(in: .whitespaces)
                }
            }

            if !foundTab.isEmpty && !foundPath.isEmpty {
                matches.append((tab: foundTab, path: foundPath))
            }
        }

        // Match against pre-normalized working directory
        if let match = matches.first(where: {
            $0.path == matchingCWD || matchingCWD.hasPrefix($0.path)
                || $0.path.hasPrefix(matchingCWD)
        }) {
            return match.tab
        }

        return matches.first?.tab
    }

    // MARK: - Low-Level Line-Buffered JSON-RPC Transport

    private func sendNotification(_ json: [String: Any]) throws {
        guard let inputPipe else { return }
        var data = try JSONSerialization.data(withJSONObject: json)
        data.append(0x0A)  // Newline delimiter
        inputPipe.fileHandleForWriting.write(data)
    }

    private func sendRPC(_ json: [String: Any]) throws -> [String: Any]? {
        guard let inputPipe, let outputPipe else { return nil }

        var data = try JSONSerialization.data(withJSONObject: json)
        data.append(0x0A)
        inputPipe.fileHandleForWriting.write(data)

        return readNextJSONLine(from: outputPipe)
    }

    private func readNextJSONLine(from pipe: Pipe) -> [String: Any]? {
        let fileHandle = pipe.fileHandleForReading

        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(..<buffer.index(after: newlineIndex))

                if lineData.isEmpty { continue }

                if let json = try? JSONSerialization.jsonObject(
                    with: Data(lineData)
                ) as? [String: Any] {
                    return json
                }
            }

            let newData = fileHandle.availableData
            if newData.isEmpty { break }
            buffer.append(newData)
        }

        return nil
    }

    deinit {
        process?.terminate()
    }
}
