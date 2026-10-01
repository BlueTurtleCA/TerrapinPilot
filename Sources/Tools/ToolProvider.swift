//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ToolProvider.swift
//

import Foundation
import Stores

/// A source of tools the agent can call (Xcode MCP bridge, web tools, ...).
public protocol ToolProvider: Sendable {
    func definitions() async -> [ToolDefinition]
    func execute(name: String, argsJSON: String, cwd: String) async -> String

    /// One-time setup for a working directory, run before the agent loop so
    /// workspace-dependent tools are ready (e.g. opening the Xcode workspace
    /// and surfacing the user's access-approval prompt up front).
    func prepare(cwd: String) async
}

public extension ToolProvider {
    func prepare(cwd: String) async {}
}

/// Routes tool calls to the provider that owns the tool.
public struct ToolRegistry: Sendable {
    private let providers: [any ToolProvider]

    public init(_ providers: [any ToolProvider]) {
        self.providers = providers
    }

    public func definitions() async -> [ToolDefinition] {
        var all: [ToolDefinition] = []
        for provider in providers {
            all.append(contentsOf: await provider.definitions())
        }
        return all
    }

    public func execute(name: String, argsJSON: String, cwd: String) async -> String {
        for provider in providers {
            let providerTools = await provider.definitions()
            guard providerTools.contains(where: { $0.function.name == name }) else {
                continue
            }
            return await provider.execute(name: name, argsJSON: argsJSON, cwd: cwd)
        }
        return "Error: Unknown tool '\(name)'"
    }

    public func prepare(cwd: String) async {
        for provider in providers {
            await provider.prepare(cwd: cwd)
        }
    }
}
