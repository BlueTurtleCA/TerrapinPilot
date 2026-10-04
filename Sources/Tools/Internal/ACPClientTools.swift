//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ACPClientTools.swift
//

import Foundation
import Stores

/// Tools backed by ACP client capabilities: filesystem access
/// (`fs/read_text_file`, `fs/write_text_file`) and terminals
/// (`terminal/*`). These run inside the client (Xcode) and are preferred
/// over the Xcode MCP bridge for file I/O and shell commands.
public final class ACPClientTools: ToolProvider, @unchecked Sendable {
    /// The client capabilities negotiated during `initialize`.
    public struct Capabilities: Sendable {
        public var readTextFile: Bool
        public var writeTextFile: Bool
        public var terminal: Bool

        public init(
            readTextFile: Bool = false,
            writeTextFile: Bool = false,
            terminal: Bool = false
        ) {
            self.readTextFile = readTextFile
            self.writeTextFile = writeTextFile
            self.terminal = terminal
        }
    }

    let channel: ClientChannel
    private let lock = NSLock()
    private var capabilities = Capabilities()

    public init(channel: ClientChannel) {
        self.channel = channel
    }

    /// Updates the negotiated client capabilities (called after `initialize`).
    public func updateCapabilities(_ capabilities: Capabilities) {
        lock.lock()
        defer { lock.unlock() }
        self.capabilities = capabilities
    }

    private var currentCapabilities: Capabilities {
        lock.lock()
        defer { lock.unlock() }
        return capabilities
    }

    // MARK: - ToolProvider Conformance

    public func definitions() async -> [ToolDefinition] {
        let capabilities = currentCapabilities
        var tools: [ToolDefinition] = []
        if capabilities.readTextFile {
            tools.append(Self.readTextFileDefinition)
        }
        if capabilities.writeTextFile {
            tools.append(Self.writeTextFileDefinition)
        }
        if capabilities.terminal {
            tools.append(contentsOf: Self.terminalDefinitions)
        }
        return tools
    }

    public func execute(name: String, argsJSON: String, cwd: String, sessionId: String) async -> String {
        let capabilities = currentCapabilities
        guard !sessionId.isEmpty else {
            return "Error: No active ACP session"
        }

        switch name {
        case "read_text_file":
            guard capabilities.readTextFile else { return Self.unsupported(name) }
            return await readTextFile(argsJSON: argsJSON, cwd: cwd, sessionId: sessionId)
        case "write_text_file":
            guard capabilities.writeTextFile else { return Self.unsupported(name) }
            return await writeTextFile(argsJSON: argsJSON, cwd: cwd, sessionId: sessionId)
        case "run_command":
            guard capabilities.terminal else { return Self.unsupported(name) }
            return await runCommand(argsJSON: argsJSON, cwd: cwd, sessionId: sessionId)
        case "terminal_create":
            guard capabilities.terminal else { return Self.unsupported(name) }
            return await createTerminalTool(argsJSON: argsJSON, cwd: cwd, sessionId: sessionId)
        case "terminal_output":
            guard capabilities.terminal else { return Self.unsupported(name) }
            return await terminalOutput(argsJSON: argsJSON, sessionId: sessionId)
        case "terminal_wait_for_exit":
            guard capabilities.terminal else { return Self.unsupported(name) }
            return await terminalWaitForExit(argsJSON: argsJSON, sessionId: sessionId)
        case "terminal_kill":
            guard capabilities.terminal else { return Self.unsupported(name) }
            return await terminalKill(argsJSON: argsJSON, sessionId: sessionId)
        case "terminal_release":
            guard capabilities.terminal else { return Self.unsupported(name) }
            return await terminalRelease(argsJSON: argsJSON, sessionId: sessionId)
        default:
            return "Error: Unknown tool '\(name)'"
        }
    }

    // MARK: - Tool Definitions

    private static let readTextFileDefinition = ToolDefinition(
        function: FunctionDefinition(
            name: "read_text_file",
            description: "Reads a text file from the client's file system, including unsaved editor changes. Prefer this over XcodeRead for reading files.",
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
            name: "write_text_file",
            description: "Writes a text file to the client's file system, creating it if it doesn't exist. Prefer this over XcodeWrite for writing files.",
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "path": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Path of the file to write. Relative paths are resolved against the working directory.")
                    ]),
                    "content": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("The full text content to write to the file.")
                    ])
                ]),
                "required": AnySendable([AnySendable("path"), AnySendable("content")])
            ]
        )
    )

    private static let terminalDefinitions: [ToolDefinition] = [
        ToolDefinition(
            function: FunctionDefinition(
                name: "run_command",
                description: "Runs a shell command in a client terminal, waits for it to finish, and returns the exit status and output. Prefer this over Xcode MCP tools for shell commands (git, swift, xcodebuild, scripts, ...).",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "command": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The command to execute, e.g. 'git'.")
                        ]),
                        "args": AnySendable([
                            "type": AnySendable("array"),
                            "items": AnySendable(["type": AnySendable("string")]),
                            "description": AnySendable("Command arguments as separate strings, e.g. [\"status\", \"-s\"].")
                        ]),
                        "cwd": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("Optional absolute working directory. Defaults to the session working directory.")
                        ]),
                        "env": AnySendable([
                            "type": AnySendable("object"),
                            "description": AnySendable("Optional environment variables as a key/value map.")
                        ]),
                        "timeoutSeconds": AnySendable([
                            "type": AnySendable("integer"),
                            "description": AnySendable("Optional maximum time to wait, in seconds (default 120, max 600). The command is killed when it elapses.")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("command")])
                ]
            )
        ),
        ToolDefinition(
            function: FunctionDefinition(
                name: "terminal_create",
                description: "Starts a command in a new client terminal and returns its terminalId. Use the other terminal tools with that id to observe, wait for, kill, or release it. Prefer run_command for one-shot commands.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "command": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The command to execute, e.g. 'swift'.")
                        ]),
                        "args": AnySendable([
                            "type": AnySendable("array"),
                            "items": AnySendable(["type": AnySendable("string")]),
                            "description": AnySendable("Command arguments as separate strings.")
                        ]),
                        "cwd": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("Optional absolute working directory. Defaults to the session working directory.")
                        ]),
                        "env": AnySendable([
                            "type": AnySendable("object"),
                            "description": AnySendable("Optional environment variables as a key/value map.")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("command")])
                ]
            )
        ),
        ToolDefinition(
            function: FunctionDefinition(
                name: "terminal_output",
                description: "Retrieves the current output of a terminal without waiting for the command to finish.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "terminalId": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The id returned by terminal_create.")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("terminalId")])
                ]
            )
        ),
        ToolDefinition(
            function: FunctionDefinition(
                name: "terminal_wait_for_exit",
                description: "Waits until the command in a terminal finishes and returns its exit status.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "terminalId": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The id returned by terminal_create.")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("terminalId")])
                ]
            )
        ),
        ToolDefinition(
            function: FunctionDefinition(
                name: "terminal_kill",
                description: "Kills the command running in a terminal without releasing it.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "terminalId": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The id returned by terminal_create.")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("terminalId")])
                ]
            )
        ),
        ToolDefinition(
            function: FunctionDefinition(
                name: "terminal_release",
                description: "Releases a terminal that is no longer needed. Always release terminals you created.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "terminalId": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The id returned by terminal_create.")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("terminalId")])
                ]
            )
        )
    ]

    // MARK: - Filesystem Tools

    private func readTextFile(argsJSON: String, cwd: String, sessionId: String) async -> String {
        guard let args = Self.parseArgs(argsJSON) else {
            return "Error: Invalid JSON parameters supplied to read_text_file"
        }
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty else {
            return "Error: Missing 'path' parameter"
        }
        let path = Self.resolvePath(rawPath, against: cwd)

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

        switch await channel.request(method: "fs/read_text_file", params: params) {
        case .result(let result):
            guard let content = result["content"] as? String else {
                return "Error: Client returned no file content for '\(path)'"
            }
            return content
        case .error(let message):
            return "Error reading '\(path)': \(message)"
        }
    }

    private func writeTextFile(argsJSON: String, cwd: String, sessionId: String) async -> String {
        guard let args = Self.parseArgs(argsJSON) else {
            return "Error: Invalid JSON parameters supplied to write_text_file"
        }
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty,
            let content = args["content"] as? String
        else {
            return "Error: Missing 'path' or 'content' parameter"
        }
        let path = Self.resolvePath(rawPath, against: cwd)

        switch await channel.request(
            method: "fs/write_text_file",
            params: ["sessionId": sessionId, "path": path, "content": content]
        ) {
        case .result:
            return "File written successfully: \(path)"
        case .error(let message):
            return "Error writing '\(path)': \(message)"
        }
    }

    // MARK: - Terminal Tools

    private enum CreatedTerminal {
        case id(String)
        case failure(String)
    }

    private func createTerminal(args: [String: Any], cwd: String, sessionId: String) async -> CreatedTerminal {
        guard let command = args["command"] as? String, !command.isEmpty else {
            return .failure("Error: Missing 'command' parameter")
        }

        var params: [String: Any] = [
            "sessionId": sessionId,
            "command": command,
            "outputByteLimit": 1_048_576,
        ]
        if !cwd.isEmpty {
            params["cwd"] = cwd
        }
        if let commandArgs = args["args"] as? [String], !commandArgs.isEmpty {
            params["args"] = commandArgs
        }
        if let rawCwd = args["cwd"] as? String, !rawCwd.isEmpty {
            params["cwd"] = Self.resolvePath(rawCwd, against: cwd)
        }
        if let env = args["env"] as? [String: Any], !env.isEmpty {
            params["env"] = env.map { key, value in
                ["name": key, "value": String(describing: value)]
            }
        }

        switch await channel.request(method: "terminal/create", params: params) {
        case .result(let result):
            guard let terminalId = result["terminalId"] as? String else {
                return .failure("Error: Client did not return a terminalId")
            }
            return .id(terminalId)
        case .error(let message):
            return .failure("Error creating terminal: \(message)")
        }
    }

    private func runCommand(argsJSON: String, cwd: String, sessionId: String) async -> String {
        guard let args = Self.parseArgs(argsJSON) else {
            return "Error: Invalid JSON parameters supplied to run_command"
        }

        let created = await createTerminal(args: args, cwd: cwd, sessionId: sessionId)
        guard case .id(let terminalId) = created else {
            if case .failure(let message) = created { return message }
            return "Error: Failed to create terminal"
        }

        let timeout = min(max((args["timeoutSeconds"] as? Int) ?? 120, 1), 600)

        // ACP's terminal/wait_for_exit has no timeout of its own, so race it
        // against a local deadline: a hung command must not hang the agent.
        let exitResponse: ClientChannel.ClientResponse? = await withTaskGroup(
            of: ClientChannel.ClientResponse?.self
        ) { group in
            group.addTask {
                await self.channel.request(
                    method: "terminal/wait_for_exit",
                    params: ["sessionId": sessionId, "terminalId": terminalId]
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        var statusLine: String
        switch exitResponse {
        case nil:
            _ = await channel.request(
                method: "terminal/kill",
                params: ["sessionId": sessionId, "terminalId": terminalId]
            )
            statusLine = "Command timed out after \(timeout)s and was killed."
        case .some(.result(let result)):
            statusLine = Self.describeExitStatus(result["exitStatus"] as? [String: Any])
        case .some(.error(let message)):
            statusLine = "Error waiting for the command to exit: \(message)"
        }

        var output = ""
        switch await channel.request(
            method: "terminal/output",
            params: ["sessionId": sessionId, "terminalId": terminalId]
        ) {
        case .result(let result):
            output = (result["output"] as? String) ?? ""
            if (result["truncated"] as? Bool) == true {
                output = "[output truncated]\n" + output
            }
        case .error(let message):
            output = "[failed to read terminal output: \(message)]"
        }

        _ = await channel.request(
            method: "terminal/release",
            params: ["sessionId": sessionId, "terminalId": terminalId]
        )

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? statusLine : statusLine + "\n" + trimmed
    }

    private func createTerminalTool(argsJSON: String, cwd: String, sessionId: String) async -> String {
        guard let args = Self.parseArgs(argsJSON) else {
            return "Error: Invalid JSON parameters supplied to terminal_create"
        }
        switch await createTerminal(args: args, cwd: cwd, sessionId: sessionId) {
        case .id(let terminalId):
            return "Terminal created: \(terminalId)"
        case .failure(let message):
            return message
        }
    }

    private func terminalOutput(argsJSON: String, sessionId: String) async -> String {
        guard let terminalId = Self.terminalId(from: argsJSON) else {
            return "Error: Missing 'terminalId' parameter"
        }
        switch await channel.request(
            method: "terminal/output",
            params: ["sessionId": sessionId, "terminalId": terminalId]
        ) {
        case .result(let result):
            var text = (result["output"] as? String) ?? ""
            if (result["truncated"] as? Bool) == true {
                text = "[output truncated]\n" + text
            }
            if let status = result["exitStatus"] as? [String: Any] {
                text += "\n" + Self.describeExitStatus(status)
            }
            return text.isEmpty ? "(no output yet)" : text
        case .error(let message):
            return "Error reading terminal output: \(message)"
        }
    }

    private func terminalWaitForExit(argsJSON: String, sessionId: String) async -> String {
        guard let terminalId = Self.terminalId(from: argsJSON) else {
            return "Error: Missing 'terminalId' parameter"
        }
        switch await channel.request(
            method: "terminal/wait_for_exit",
            params: ["sessionId": sessionId, "terminalId": terminalId]
        ) {
        case .result(let result):
            return Self.describeExitStatus(result["exitStatus"] as? [String: Any])
        case .error(let message):
            return "Error waiting for terminal exit: \(message)"
        }
    }

    private func terminalKill(argsJSON: String, sessionId: String) async -> String {
        guard let terminalId = Self.terminalId(from: argsJSON) else {
            return "Error: Missing 'terminalId' parameter"
        }
        switch await channel.request(
            method: "terminal/kill",
            params: ["sessionId": sessionId, "terminalId": terminalId]
        ) {
        case .result:
            return "Terminal \(terminalId) killed."
        case .error(let message):
            return "Error killing terminal: \(message)"
        }
    }

    private func terminalRelease(argsJSON: String, sessionId: String) async -> String {
        guard let terminalId = Self.terminalId(from: argsJSON) else {
            return "Error: Missing 'terminalId' parameter"
        }
        switch await channel.request(
            method: "terminal/release",
            params: ["sessionId": sessionId, "terminalId": terminalId]
        ) {
        case .result:
            return "Terminal \(terminalId) released."
        case .error(let message):
            return "Error releasing terminal: \(message)"
        }
    }

    // MARK: - Helpers

    private static func unsupported(_ name: String) -> String {
        "Error: The client does not support the '\(name)' capability"
    }

    private static func parseArgs(_ argsJSON: String) -> [String: Any]? {
        guard let data = argsJSON.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func terminalId(from argsJSON: String) -> String? {
        parseArgs(argsJSON)?["terminalId"] as? String
    }

    private static func resolvePath(_ path: String, against cwd: String) -> String {
        if path.hasPrefix("/") { return path }
        guard !cwd.isEmpty else { return path }
        return cwd.hasSuffix("/") ? cwd + path : cwd + "/" + path
    }

    private static func describeExitStatus(_ status: [String: Any]?) -> String {
        guard let status else { return "Command finished." }
        if let code = status["exitCode"] as? Int {
            return code == 0
                ? "Command finished with exit code 0."
                : "Command failed with exit code \(code)."
        }
        if let signal = status["signal"] as? String {
            return "Command terminated by signal \(signal)."
        }
        return "Command finished."
    }
}
