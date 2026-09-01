//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// SessionStore.swift
//

import Foundation

public actor SessionStore {
    private var workingDirs: [String: String] = [:]
    private var histories: [String: [ChatMessage]] = [:]
    
    public init() {}
    
    private func normalizePath(_ rawPath: String) -> String {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Strip file:// URI scheme if present
        if path.hasPrefix("file://") {
            if let url = URL(string: path) {
                path = url.path
            } else {
                path = String(path.dropFirst(7))
            }
        }

        // 2. Expand tilde (~) paths
        path = (path as NSString).expandingTildeInPath

        // 3. Strip SPM metadata directories
        if path.hasSuffix("/.swiftpm/xcode") {
            path = String(path.dropLast("/.swiftpm/xcode".count))
        } else if let index = path.range(of: "/.swiftpm/")?.lowerBound {
            path = String(path[..<index])
        }

        // 4. Strip .xcodeproj / .xcworkspace bundle paths if passed as CWD
        if path.hasSuffix(".xcodeproj") || path.hasSuffix(".xcworkspace") {
            path = (path as NSString).deletingLastPathComponent
        }

        // 5. Standardize path and resolve symlinks (/var -> /private/var)
        let fileURL = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
        path = fileURL.path

        // 6. Ensure NFC Unicode normalization for APFS filesystem compatibility
        return path.precomposedStringWithCanonicalMapping
    }
    
    // Set CWD when session/new or prompt comes in
    public func setCWD(_ cwd: String, for sessionId: String) {
        workingDirs[sessionId] = normalizePath(cwd)
    }
    
    // Retrieve CWD for a given session
    public func getCWD(for sessionId: String) -> String? {
        return workingDirs[sessionId]
    }
    
    // Get chat history or fallback to standard system prompt
    public func getHistory(for sessionId: String, defaultSystemPrompt: String) -> [ChatMessage] {
        return histories[sessionId] ?? [
            ChatMessage(role: "system", content: defaultSystemPrompt)
        ]
    }
    
    // Save updated conversation history
    public func saveHistory(_ history: [ChatMessage], for sessionId: String) {
        histories[sessionId] = history
    }
}
