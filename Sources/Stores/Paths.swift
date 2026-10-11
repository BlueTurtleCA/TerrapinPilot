//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// Paths.swift
//

import Foundation

/// Centralized on-disk locations for TerrapinPilot.
///
/// User-level state lives under `~/.terrapinpilot/`; workspace-level scratch
/// lives under `./.terrapinpilot/` in the session's working directory.
public enum TerrapinPaths {
    /// User-level root: `~/.terrapinpilot`.
    public static var userDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("terrapinpilot", isDirectory: true)
    }

    /// Persisted session state: `~/.terrapinpilot/sessions`.
    public static var sessionsDirectory: URL {
        userDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    /// LLM request debug logs: `~/.terrapinpilot/logs`.
    public static var logsDirectory: URL {
        userDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    /// Workspace-level scratch directory name (web fetch cache, ...).
    public static let workspaceDirectoryName = "terrapinpilot"

    /// Workspace-level web fetch cache: `./.terrapinpilot/web` under `cwd`.
    public static func webCacheDirectory(in cwd: String) -> String {
        (cwd as NSString).appendingPathComponent(
            workspaceDirectoryName + "/web"
        )
    }
}
