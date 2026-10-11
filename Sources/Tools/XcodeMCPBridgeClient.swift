//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// XcodeMCPBridgeClient.swift
//

import Foundation
import Logger
import Stores

public actor XcodeMCPBridgeClient: ToolProvider {
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var buffer = Data()
    private var logger: Loggable

    private var activeTabIdentifier: String?
    private var activeWorkspaceIdentifier: String?
    private var tools: [ToolDefinition] = []
    private var openedWorkspacePath: String?
    private var started = false
    
    /// True once `start()` has spawned the mcpbridge process.
    public var isStarted: Bool { started }

    public func definitions() async -> [ToolDefinition] { tools }

    // File tools (XcodeMV, XcodeRM, XcodeLS) are intentionally not exposed:
    // the wrapper tools (move_file, delete_file, list_directory) prefer the
    // bridge internally and fall back to local operations when it fails.
    private let allowedMCPBridgeTools: Set<String> = [
        "BuildProject",
        "GetBuildLog",
        "XcodeListNavigatorIssues",
        "XcodeRefreshCodeIssuesInFile",
        "RunSomeTests",
        "RunAllTests",
        "RunCodeSnippet",
        "RenderPreview",
        "DocumentationSearch",
        "XcodeOpenWorkspace"
    ]
    
    public func execute(name: String, argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void)
        async -> String
    {
        let callId = "call_" + UUID().uuidString
        let (kind, title) = categorizeMCPTool(name: name, argsJSON: argsJSON)
        
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "tool_call",
                    "toolCallId": callId,
                    "name": name,
                    "title": title,
                    "kind": kind,
                    "status": "in_progress"
                ]
            ]
        ])
        
        let result = await callTool(name: name, argsJSON: argsJSON, cwd: cwd)
        
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": callId,
                    "status": result.starts(with: "Error") ? "failed" : "completed"
                ]
            ]
        ])
        
        return result
    }

    /// Opens the Xcode workspace for `cwd` before the agent loop so that
    /// workspace-dependent tools (XcodeRead, ...) work on the first call and
    /// the user's access-approval prompt appears up front instead of after a
    /// refused read. No-op if this workspace is already open.
    public func prepare(cwd: String) async {
        guard !cwd.isEmpty, openedWorkspacePath != cwd else { return }

        let args: [String: Any] = ["path": cwd]
        let argsJSON =
            (try? JSONSerialization.data(withJSONObject: args))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let result = await callTool(
            name: "XcodeOpenWorkspace",
            argsJSON: argsJSON,
            cwd: cwd
        )
        logger.debug("XcodeOpenWorkspace(\(cwd)): \(result)")

        // The bridge identifies workspaces by an opaque identifier (e.g.
        // "workspace-LR49lofe9w"), not by path, so capture it from the open
        // response and fall back to listing workspaces if it is missing.
        // Only mark the workspace as opened once an identifier is resolved;
        // otherwise the next turn retries the open.
        if let identifier = parseWorkspaceIdentifier(from: result) {
            activeWorkspaceIdentifier = identifier
            openedWorkspacePath = cwd
        } else if let resolved = await resolveWorkspaceIdentifier(matchingCWD: cwd) {
            activeWorkspaceIdentifier = resolved
            openedWorkspacePath = cwd
        }
    }

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
        started = true

        // 2. Step 1 of MCP Handshake: Send initialize request
        let initRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "TerrapinPilot", "version": "1.0.0"],
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
    @discardableResult
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
                allowedMCPBridgeTools.contains(name),
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

        self.tools = tools
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

        // 2. Auto-inject the cached workspace identifier if missing, since Xcode
        //    workspace tools require it to resolve the target project. When no
        //    identifier is cached, omit the field: the bridge's error then drives
        //    the resolve-and-retry below instead of injecting a raw path the
        //    bridge would reject as unknown.
        if argsDict["workspaceIdentifier"] == nil,
            let cachedWorkspace = activeWorkspaceIdentifier
        {
            argsDict["workspaceIdentifier"] = cachedWorkspace
        }
                
        // Send initial RPC tool call request
        let response = sendToolRPC(name: name, argsDict: argsDict)
        let outputText = parseToolOutput(response: response, name: name)

        // Cache the identifier returned by an explicit open (whether triggered
        // by prepare or by the model calling XcodeOpenWorkspace) so subsequent
        // calls inject it without re-resolving.
        if name == "XcodeOpenWorkspace",
            let identifier = parseWorkspaceIdentifier(from: outputText)
        {
            activeWorkspaceIdentifier = identifier
        }

        // 3. Check if mcpbridge threw a tabIdentifier required error
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

        // 4. If the bridge rejects the injected workspace identifier (or none
        //    was available), resolve the correct one from XcodeListWorkspaces
        //    and retry once.
        if name != "XcodeListWorkspaces",
            outputText.contains("Unknown workspace identifier")
                || outputText.contains("workspaceIdentifier is required")
        {
            if let resolved = await resolveWorkspaceIdentifier(matchingCWD: cwd) {
                activeWorkspaceIdentifier = resolved
                argsDict["workspaceIdentifier"] = resolved
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

    /// Extracts the `workspaceIdentifier` field from an XcodeOpenWorkspace
    /// response, e.g. `{"workspaceIdentifier":"workspace-LR49lofe9w", ...}`.
    /// Tries a strict whole-text JSON parse first, then falls back to scanning
    /// for the field so responses with surrounding prose still resolve.
    private func parseWorkspaceIdentifier(from text: String) -> String? {
        if let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let identifier = json["workspaceIdentifier"] as? String,
            !identifier.isEmpty
        {
            return identifier
        }

        guard let match = text.firstMatch(
            of: /"workspaceIdentifier"\s*:\s*"([^"]+)"/
        ) else { return nil }
        let identifier = String(match.1)
        return identifier.isEmpty ? nil : identifier
    }

    /// Lists open workspaces and returns the identifier whose `workspacePath`
    /// matches `cwd`. When a project appears as both a workspace and a window
    /// tab, the workspace-level identifier is preferred.
    private func resolveWorkspaceIdentifier(matchingCWD cwd: String) async -> String? {
        let result = await callTool(name: "XcodeListWorkspaces", argsJSON: "{}", cwd: cwd)
        logger.debug("XcodeListWorkspaces: \(result)")

        var fallback: String?
        for line in result.components(separatedBy: .newlines)
        where line.contains("workspaceIdentifier:") && line.contains("workspacePath:")
        {
            var identifier = ""
            var path = ""
            for part in line.components(separatedBy: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("workspaceIdentifier:") {
                    identifier = trimmed
                        .replacingOccurrences(of: "workspaceIdentifier:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                } else if trimmed.contains("workspacePath:") {
                    path = trimmed
                        .replacingOccurrences(of: "workspacePath:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            guard !identifier.isEmpty, !path.isEmpty else { continue }
            if path == cwd || cwd.hasPrefix(path) || path.hasPrefix(cwd) {
                if identifier.hasPrefix("workspace-") {
                    return identifier
                }
                fallback = identifier
            }
        }
        return fallback
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

    private func categorizeMCPTool(name: String, argsJSON: String) -> (kind: String, title: String) {
        switch name {
        case "BuildProject":
            return ("execute", name)
        case "XcodeClean":
            return ("execute", name)
        case "RunSomeTests", "RunAllTests":
            return ("execute", name)
        case "RunCodeSnippet":
            return ("execute", "Running Code Snippet")
        case "DocumentationSearch":
            return ("other", "Searching Apple Documentation")
        case "GetBuildLog", "XcodeListNavigatorIssues":
            return ("other", "Fetching Xcode Diagnostics with \(name)")
        case "XcodeRefreshCodeIssuesInFile":
            return ("other", "Refreshing Code Issues")
        case "RenderPreview":
            return ("other", "Rendering SwiftUI Preview")
        default:
            return ("execute", name)
        }
    }
    
    deinit {
        process?.terminate()
    }
}
