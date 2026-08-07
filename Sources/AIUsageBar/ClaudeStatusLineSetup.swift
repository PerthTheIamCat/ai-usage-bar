import Foundation

/// Installs and detects the Claude Code CLI statusLine bridge. This only
/// covers the CLI path — Claude Desktop needs no setup since AI Usage Bar
/// reads its local plan-usage file directly (see `ClaudeLimitsReader`).
enum ClaudeStatusLineSetup {
    enum State {
        case configured
        /// Bridge script exists but `~/.claude/settings.json` doesn't point
        /// to it — either untouched, or already running a different command.
        case notConfigured
    }

    static let claudeDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true)
    static let bridgeScriptURL = claudeDir.appendingPathComponent("ai-usage-bar-statusline.sh")
    static let settingsURL = claudeDir.appendingPathComponent("settings.json")

    private static let bridgeScriptContents = """
        #!/bin/zsh
        # Claude Code statusLine bridge for AI Usage Bar.
        # Claude Code sends JSON on stdin; the app stores only rate_limits locally and
        # prints a compact status line back to Claude Code.
        set -u

        APP_BIN="${AI_USAGE_BAR_BIN:-/Applications/AIUsageBar.app/Contents/MacOS/AIUsageBar}"
        if [[ ! -x "$APP_BIN" ]]; then
            print -u2 "AIUsageBar statusline bridge: app not found at $APP_BIN"
            exit 0
        fi

        exec "$APP_BIN" --claude-statusline

        """

    static func currentState() -> State {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = obj["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String
        else { return .notConfigured }
        return command.contains("ai-usage-bar-statusline.sh") ? .configured : .notConfigured
    }

    enum InstallError: LocalizedError {
        case conflictingStatusLine
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .conflictingStatusLine:
                return "A different statusLine command is already configured in ~/.claude/settings.json. Merge the bridge command in manually."
            case .writeFailed(let reason):
                return "Could not update ~/.claude/settings.json: \(reason)"
            }
        }
    }

    /// Writes the bridge script and, only if `~/.claude/settings.json` has no
    /// `statusLine` entry at all, adds ours. Never touches an existing
    /// different `statusLine` — the settings file is edited by inserting the
    /// new key next to the opening brace rather than re-serializing the
    /// whole document, so unrelated formatting is left alone.
    @discardableResult
    static func install() -> Result<Void, InstallError> {
        do {
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            try bridgeScriptContents.write(to: bridgeScriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridgeScriptURL.path)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }

        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return writeNewSettingsFile()
        }

        guard let text = try? String(contentsOf: settingsURL, encoding: .utf8) else {
            return .failure(.writeFailed("could not read the existing file"))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return .failure(.writeFailed("existing file is not valid JSON"))
        }
        if obj["statusLine"] != nil {
            return .failure(.conflictingStatusLine)
        }
        // Inserting `"statusLine": {…},` after the opening brace of an empty
        // object leaves a trailing comma and produces invalid JSON, which
        // would break Claude Code's own config. There is nothing to preserve
        // in that case, so write a clean file instead.
        guard !obj.isEmpty else { return writeNewSettingsFile() }

        guard let braceRange = text.range(of: "{") else {
            return .failure(.writeFailed("existing file has no top-level object"))
        }
        let entry = "\n  \"statusLine\": {\"type\": \"command\", \"command\": \"\(bridgeScriptURL.path)\"},"
        var updated = text
        updated.insert(contentsOf: entry, at: braceRange.upperBound)

        // Keep the change reversible without relying on other tools' backups.
        // If the backup can't be written, don't touch the real file either —
        // silently proceeding would drop the safety net without saying so.
        let backupURL = claudeDir.appendingPathComponent("settings.json.bak-aiusagebar")
        do {
            try text.write(to: backupURL, atomically: true, encoding: .utf8)
        } catch {
            return .failure(.writeFailed("could not write backup: \(error.localizedDescription)"))
        }

        do {
            try updated.write(to: settingsURL, atomically: true, encoding: .utf8)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
        return .success(())
    }

    private static func writeNewSettingsFile() -> Result<Void, InstallError> {
        let contents = """
            {
              "statusLine": {"type": "command", "command": "\(bridgeScriptURL.path)"}
            }
            """
        do {
            try contents.write(to: settingsURL, atomically: true, encoding: .utf8)
            return .success(())
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }
}
