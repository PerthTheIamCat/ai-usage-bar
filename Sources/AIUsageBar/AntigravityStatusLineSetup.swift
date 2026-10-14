import Foundation

/// Installs the Antigravity CLI status-line bridge. Antigravity provides its
/// authenticated quota response to the configured command on stdin; the
/// bridge stores only the derived windows used by the menu bar.
enum AntigravityStatusLineSetup {
    enum State {
        case configured
        case notConfigured
    }

    static let antigravityDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
    static let bridgeScriptURL = scriptURL(in: antigravityDir)
    static let settingsURL = settingsFileURL(in: antigravityDir)

    // Directory-parameterised so tests can exercise install() against a
    // temporary directory instead of the real ~/.gemini/antigravity-cli.
    static func scriptURL(in directory: URL) -> URL {
        directory.appendingPathComponent("ai-usage-bar-statusline.sh")
    }

    static func settingsFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("settings.json")
    }

    private static let bridgeScriptContents = """
        #!/bin/zsh
        # Antigravity CLI statusLine bridge for AI Usage Bar.
        # Antigravity sends its status JSON on stdin; the app stores only quota windows.
        set -u

        APP_BIN="${AI_USAGE_BAR_BIN:-/Applications/AIUsageBar.app/Contents/MacOS/AIUsageBar}"
        if [[ ! -x "$APP_BIN" ]]; then
            print -u2 "AIUsageBar Antigravity bridge: app not found at $APP_BIN"
            exit 0
        fi

        exec "$APP_BIN" --antigravity-statusline

        """

    static func currentState(in directory: URL = antigravityDir) -> State {
        guard let data = try? Data(contentsOf: settingsFileURL(in: directory)),
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
                return "A different statusLine command is already configured in ~/.gemini/antigravity-cli/settings.json. Merge the bridge command in manually."
            case .writeFailed(let reason):
                return "Could not update ~/.gemini/antigravity-cli/settings.json: \(reason)"
            }
        }
    }

    /// Writes the executable bridge and adds a statusLine only when the user
    /// has not configured another one. Existing settings are backed up before
    /// they are changed so the setup remains reversible.
    @discardableResult
    static func install(in directory: URL = antigravityDir) -> Result<Void, InstallError> {
        let bridgeScriptURL = scriptURL(in: directory)
        let settingsURL = settingsFileURL(in: directory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bridgeScriptContents.write(to: bridgeScriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridgeScriptURL.path)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }

        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return writeNewSettingsFile(settingsURL: settingsURL, bridgeScriptURL: bridgeScriptURL)
        }
        guard let text = try? String(contentsOf: settingsURL, encoding: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else {
            return .failure(.writeFailed("existing file is not valid JSON"))
        }
        if let statusLine = obj["statusLine"] {
            if let command = (statusLine as? [String: Any])?["command"] as? String,
               command.contains("ai-usage-bar-statusline.sh") {
                return .success(())
            }
            return .failure(.conflictingStatusLine)
        }

        let entry = "\n  \"statusLine\": {\"type\": \"command\", \"command\": \"\(bridgeScriptURL.path)\", \"stack_with_default\": true},"
        let updated: String
        if obj.isEmpty {
            updated = "{\n  \"statusLine\": {\"type\": \"command\", \"command\": \"\(bridgeScriptURL.path)\", \"stack_with_default\": true}\n}\n"
        } else if let braceRange = text.range(of: "{") {
            var value = text
            value.insert(contentsOf: entry, at: braceRange.upperBound)
            updated = value
        } else {
            return .failure(.writeFailed("existing file has no top-level object"))
        }

        let backupURL = directory.appendingPathComponent("settings.json.bak-aiusagebar")
        do {
            try text.write(to: backupURL, atomically: true, encoding: .utf8)
            try updated.write(to: settingsURL, atomically: true, encoding: .utf8)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
        return .success(())
    }

    private static func writeNewSettingsFile(settingsURL: URL, bridgeScriptURL: URL) -> Result<Void, InstallError> {
        let contents = """
            {
              "statusLine": {"type": "command", "command": "\(bridgeScriptURL.path)", "stack_with_default": true}
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
