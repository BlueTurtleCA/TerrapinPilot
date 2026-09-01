//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ChatMessage.swift
//

import Foundation

public struct ChatMessage: Codable, Sendable {
    public var role: String
    public var content: String?
    public var toolCallId: String?
    public var name: String?
    public var toolCalls: [ToolCall]?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCallId = "tool_call_id"
        case name
        case toolCalls = "tool_calls"
    }

    public init(
        role: String,
        content: String? = nil,
        toolCallId: String? = nil,
        name: String? = nil,
        toolCalls: [ToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCallId = toolCallId
        self.name = name
        self.toolCalls = toolCalls
    }
}

public struct ToolCall: Codable, Sendable {
    public var id: String
    public var type: String
    public var function: FunctionCall

    public init(id: String, type: String = "function", function: FunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct FunctionCall: Codable, Sendable {
    public var name: String
    public var arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}
