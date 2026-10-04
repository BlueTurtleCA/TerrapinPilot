//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ACPWrapperTools.swift
//

import Foundation
import Stores

public final class ACPWrapperTools: ToolProvider, @unchecked Sendable {
    let acpClientTools: ACPClientTools
    let clientChannel: ClientChannel
    
    enum ACPError: Error {
        case message(String)
    }
    
    public init(clientChannel: ClientChannel) {
        self.acpClientTools = ACPClientTools(channel: clientChannel)
        self.clientChannel = clientChannel
    }
    
    public func definitions() async -> [ToolDefinition] {
        var tools: [ToolDefinition] = []
        tools.append(Self.readTextFileDefinition)
        tools.append(Self.writeTextFileDefinition)
        tools.append(Self.editTextFileDefinition)
        tools.append(Self.grepTextFileDefinition)
        return tools
    }
    
    public func execute(name: String, argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        guard !sessionId.isEmpty else {
            return "Error: No active ACP session"
        }

        switch name {
        case "read_file":
            return await readTextFile(argsJSON: argsJSON, cwd: cwd, sessionId: sessionId, sendJSON: sendJSON)
        case "write_file":
            return await writeTextFile(argsJSON: argsJSON, cwd: cwd, sessionId: sessionId, sendJSON: sendJSON)
        case "edit_file":
            return await editTextFile(argsJSON: argsJSON, cwd: cwd, sessionId: sessionId, sendJSON: sendJSON)
        case "grep_file":
            return await grepTextFile(argsJSON: argsJSON, cwd: cwd, sessionId: sessionId, sendJSON: sendJSON)
        default:
            return "Error: Unknown tool '\(name)'"
        }
    }
    
    public func updateCapabilities(_ capabilities: Capabilities) {
        self.acpClientTools.updateCapabilities(capabilities)
    }
    
    private static let readTextFileDefinition = ToolDefinition(
        function: FunctionDefinition(
            name: "read_file",
            description: "Reads a text file from the client's file system, including unsaved editor changes. For any project files, you MUST use this call.",
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "path": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Path of the file to read. Relative paths are resolved against the working directory.")
                    ]),
                    "line": AnySendable([
                        "type": AnySendable("integer"),
                        "description": AnySendable("Optional 1-based line number to start reading from.")
                    ]),
                    "limit": AnySendable([
                        "type": AnySendable("integer"),
                        "description": AnySendable("Optional maximum number of lines to read.")
                    ])
                ]),
                "required": AnySendable([AnySendable("path")])
            ]
        )
    )
    
    private static let writeTextFileDefinition = ToolDefinition(
        function: FunctionDefinition(
            name: "write_file",
            description: "Writes a complete file to the client's file system. For creating or overwriting any project files, you MUST use this call.",
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "path": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Path of the file to read. Relative paths are resolved against the working directory.")
                    ]),
                    "content": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("The full file content to write to the disk")
                    ])
                ]),
                "required": AnySendable([AnySendable("path"), AnySendable("content")])
            ]
        )
    )
    
    private static let editTextFileDefinition = ToolDefinition(
        function: FunctionDefinition(
            name: "edit_file",
            description: "Edits a file by replacing one text block for another. Edits MUST match the old text identically, including whitespace and newlines.",
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "path": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Path of the file to read. Relative paths are resolved against the working directory.")
                    ]),
                    "existingText": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("The existing text of the file to replace.")
                    ]),
                    "newText": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("The text to overwrite the existingText with.")
                    ])
                ]),
                "required": AnySendable([AnySendable("path"), AnySendable("existingText"), AnySendable("newText")])
            ]
        )
    )
    
    private static let grepTextFileDefinition = ToolDefinition(
        function: FunctionDefinition(
            name: "grep_file",
            description: "Searches workspace files for a text string or regex pattern.",
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "query": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("The exact text or regex pattern to search for.")
                    ]),
                    "pathPattern": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Optional glob filter (e.g. '*.swift', 'Sources/*').")
                    ]),
                    "caseSensitive": AnySendable([
                        "type": AnySendable("boolean"),
                        "description": AnySendable("Whether the search should be case sensitive. Defaults to false.")
                    ])
                ]),
                "required": AnySendable([AnySendable("query")])
            ]
        )
    )
    
    // MARK: - Filesystem Tools

    private func readTextFile(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        let callId = "call_" + UUID().uuidString
        
        guard let args = Self.parseArgs(argsJSON) else {
            return "Error: Invalid JSON parameters supplied to read_file"
        }
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty else {
            return "Error: Missing 'path' parameter"
        }
        let path = Self.resolveWorkspacePath(relativePath: rawPath, workspaceRoot: cwd)
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "tool_call",
                    "toolCallId": callId,
                    "name": "read_file",
                    "title": "Reading \(fileName)",
                    "kind": "read",
                    "status": "in_progress",
                    "locations": [["path": path]]
                ]
            ]
        ])
        
        var params: [String: Any] = [
            "sessionId": sessionId,
            "path": path,
        ]
        if let line = args["line"] as? Int {
            params["line"] = line
        }
        if let limit = args["limit"] as? Int {
            params["limit"] = limit
        }
        
        do {
            switch await clientChannel.request(method: "fs/read_text_file", params: params) {
            case .result(let result):
                guard let response = result["content"] as? String else {
                    throw ACPError.message("Error reading text file: No content from \(path)")
                }
                
                sendJSON([
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": [
                        "sessionId": sessionId,
                        "update": [
                            "sessionUpdate": "tool_call_update",
                            "toolCallId": callId,
                            "status": "completed"
                        ]
                    ]
                ])
                
                return response
                
            case .error(let message):
                throw ACPError.message("Error reading text file \(path): message \(message)")
            }
        } catch ACPError.message(let reason) {
            return reason
        } catch {
            return "Other error reading text file: \(error.localizedDescription)"
        }
    }
    
    private func writeTextFile(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        let callId = "call_" + UUID().uuidString
        
        guard let args = Self.parseArgs(argsJSON) else {
            return "Error: Invalid JSON parameters supplied to write_file"
        }
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty,
              let content = args["content"] as? String
                else {
            return "Error: Missing 'path' or 'content' parameter"
        }
        let path = Self.resolveWorkspacePath(relativePath: rawPath, workspaceRoot: cwd)
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        
        let oldText = try? await internalReadTextFile(clientChannel: self.clientChannel, sessionId: sessionId, path: path)
        
        var update: [String: Any] = [
            "sessionUpdate": "tool_call",
            "toolCallId": callId,
            "name": "write_file",
            "title": "Writing \(fileName)",
            "kind": "edit",
            "status": "in_progress",
            "locations": [
                ["path": path]
            ]
        ];
        
        if oldText != nil {
            update["content"] = [
                [
                    "type": "diff",
                    "path": path,
                    "oldText": oldText,
                    "newText": content
                ]
            ];
        }
        
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": update
            ]
        ])
        
        switch await clientChannel.request(
            method: "fs/write_text_file",
            params: ["sessionId": sessionId, "path": path, "content": content]
        ) {
        case .result:
            sendJSON([
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": [
                    "sessionId": sessionId,
                    "update": [
                        "sessionUpdate": "tool_call_update",
                        "toolCallId": callId,
                        "status": "completed"
                    ],
                    "locations": [
                        ["path": path]
                    ],
                    "content": [
                        [
                            "type": "diff",
                            "path": path,
                            "oldText": oldText,
                            "newText": content
                        ]
                    ]
                ]
            ])
            
            return "File written successfully: \(path)"
        case .error(let message):
            sendJSON([
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": [
                    "sessionId": sessionId,
                    "update": [
                        "sessionUpdate": "tool_call_update",
                        "toolCallId": callId,
                        "status": "failed"
                    ]
                ]
            ])
            return "Error writing '\(path)': \(message)"
        }
    }
    
    private func editTextFile(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        let callId = "call_" + UUID().uuidString
        
        guard let args = Self.parseArgs(argsJSON) else {
            return "Error: Invalid JSON parameters supplied to write_file"
        }
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty,
              let existingText = args["existingText"] as? String,
              let newText = args["newText"] as? String
                else {
            return "Error: Missing 'path' or 'existingText' or 'newText' parameter"
        }
        
        let path = Self.resolveWorkspacePath(relativePath: rawPath, workspaceRoot: cwd)
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        
        guard let currentText = try? await internalReadTextFile(clientChannel: self.clientChannel, sessionId: sessionId, path: path) else {
            return "Error: Could not read text from \(path). Verify that this file exists before editing."
        }
        
        let occurrences = currentText.components(separatedBy: existingText).count - 1

        if occurrences == 0 {
            return "Error: Could not find 'old_string' in \(fileName). Verify exact indentation and line breaks."
        }

        if occurrences > 1 {
            return """
            Error: 'old_string' matched \(occurrences) locations in \(fileName). \
            Please include surrounding context lines (e.g., enclosing function name or adjacent variables) \
            so the target block is uniquely identifiable.
            """
        }

        let updatedText = currentText.replacingOccurrences(of: existingText, with: newText)
        
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "tool_call",
                    "toolCallId": callId,
                    "name": "write_file",
                    "title": "Writing \(fileName)",
                    "kind": "edit",
                    "status": "in_progress",
                    "locations": [
                        ["path": path]
                    ],
                    "content": [
                        [
                            "type": "diff",
                            "path": path,
                            "oldText": currentText,
                            "newText": updatedText
                        ]
                    ]
                ]
            ]
        ])
        
        switch await clientChannel.request(
            method: "fs/write_text_file",
            params: ["sessionId": sessionId, "path": path, "content": updatedText]
        ) {
        case .result:
            sendJSON([
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": [
                    "sessionId": sessionId,
                    "update": [
                        "sessionUpdate": "tool_call_update",
                        "toolCallId": callId,
                        "status": "completed"
                    ],
                    "locations": [
                        ["path": path]
                    ],
                    "content": [
                        [
                            "type": "diff",
                            "path": path,
                            "oldText": currentText,
                            "newText": updatedText
                        ]
                    ]
                ]
            ])
            
            return "File written successfully: \(path)"
        case .error(let message):
            sendJSON([
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": [
                    "sessionId": sessionId,
                    "update": [
                        "sessionUpdate": "tool_call_update",
                        "toolCallId": callId,
                        "status": "failed"
                    ]
                ]
            ])
            return "Error writing '\(path)': \(message)"
        }
    }
    
    private func grepTextFile(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        let callId = "call_" + UUID().uuidString
        
        guard let args = Self.parseArgs(argsJSON) else {
            return "Error: Invalid JSON parameters supplied to grep_file"
        }
        guard let query = args["query"] as? String, !query.isEmpty
                else {
            return "Error: Missing or empty 'query' parameter"
        }
        
        let pathPattern = args["path_pattern"] as? String
        let caseSensitive = args["case_sensitive"] as? Bool ?? false
        
            
        let (matches, _) = await runStandardGrep(
            query: query,
            cwd: cwd,
            pathPattern: pathPattern,
            caseSensitive: caseSensitive
        )
        
        let resultText = matches.isEmpty ? "No matches found for '\(query)'." : matches.joined(separator: "\n")
        
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "tool_call",
                    "toolCallId": callId,
                    "name": "grep_file",
                    "title": "Grep searching for \(query)",
                    "kind": "execute",
                    "status": "in_progress"
                ]
            ]
        ])
        
        
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": callId,
                    "status": "completed"
                ]
            ]
        ])
            
        return resultText
    }
    
    private func internalReadTextFile(clientChannel: ClientChannel, sessionId: String, path: String) async throws -> String {
        do {            
            do {
                switch await clientChannel.request(method: "fs/read_text_file", params: [
                    "sessionId": sessionId,
                    "path": path,
                ]) {
                case .result(let result):
                    guard let response = result["content"] as? String else {
                        throw ACPError.message("Error reading text file: No content from \(path)")
                    }
                    return response
                    
                case .error(let message):
                    throw ACPError.message("Error reading text file \(path): message \(message)")
                }
            } catch {
                throw error
            }
        } catch {
            if FileManager.default.fileExists(atPath: path) {
                return try String(contentsOfFile: path, encoding: .utf8)
            }
            throw error
        }
    }
    
    private static func parseArgs(_ argsJSON: String) -> [String: Any]? {
        guard let data = argsJSON.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func resolveWorkspacePath(relativePath: String, workspaceRoot: String) -> String {
        let expandedRaw = (relativePath as NSString).expandingTildeInPath
        let expandedRoot = (workspaceRoot as NSString).expandingTildeInPath
        
        let rootURL = URL(fileURLWithPath: expandedRoot).standardizedFileURL
            
        // 1. Absolute paths
        if expandedRaw.hasPrefix("/") {
            return URL(fileURLWithPath: expandedRaw).standardizedFileURL.path
        }
            
        // 2. Strip redundant workspace name prefix EVEN IF the file doesn't exist yet
        let rootName = rootURL.lastPathComponent // "TerrapinPilot"
        var cleanRelative = expandedRaw
        if expandedRaw.hasPrefix("\(rootName)/") {
            cleanRelative = String(expandedRaw.dropFirst(rootName.count + 1)) // "SUMMARY.md"
        }
            
        // 3. Resolve clean path against workspace root
        let resolvedURL = rootURL.appendingPathComponent(cleanRelative).standardizedFileURL
        return resolvedURL.path
    }
    
    private func runStandardGrep(
        query: String,
        cwd: String,
        pathPattern: String?,
        caseSensitive: Bool
    ) async -> (matches: [String], locations: [[String: Any]]) {
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        
        var arguments = [
            "-r",
            "-n",
            "-H",
            "-I",
            "--exclude-dir=.git",
            "--exclude-dir=.build",
            "--exclude-dir=DerivedData"
        ]
        
        if !caseSensitive { arguments.append("-i") }
        if let pattern = pathPattern, !pattern.isEmpty {
            arguments.append(contentsOf: ["--include", pattern])
        }
        arguments.append(contentsOf: ["-e", query, cwd])
        
        process.arguments = arguments
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return ([], [])
            }
            
            var matches: [String] = []
            var locations: [[String: Any]] = []
            
            let lines = output.components(separatedBy: .newlines)
            for line in lines.prefix(100) where !line.isEmpty {
                matches.append(line)
                
                // Format: /Users/.../File.swift:42:let foo = "bar"
                let parts = line.components(separatedBy: ":")
                if parts.count >= 3, let lineNumber = Int(parts[1]) {
                    let rawPath = parts[0]
                    
                    // CRITICAL: Guarantee 100% absolute POSIX path for AgentSearch
                    let absPath = Self.resolveWorkspacePath(relativePath: rawPath, workspaceRoot: cwd)
                    
                    locations.append([
                        "path": absPath,
                        "line": lineNumber,
                        "column": 1
                    ])
                }
            }
            
            return (matches, locations)
        } catch {
            return (["Grep execution failed: \(error.localizedDescription)"], [])
        }
    }
}
