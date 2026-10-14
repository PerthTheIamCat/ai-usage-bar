import Foundation

/// An additional Claude Code or Codex account, read from its own config
/// directory. The default account (`~/.claude`, `~/.codex`) is always read and
/// is not stored here; these are the extra ones people add in Settings →
/// Accounts, typically a second `CLAUDE_CONFIG_DIR` / `CODEX_HOME`.
struct ExtraAccount: Codable, Identifiable, Equatable {
    /// Stable, filename-safe identifier (`claude-work`). Also names this
    /// account's status-line snapshot file, so it never contains a path
    /// separator.
    var id: String
    var provider: ProviderKind
    var name: String
    /// The account's config directory — the folder that contains `projects/`
    /// for Claude or `sessions/` for Codex. May start with `~`.
    var path: String

    /// Only providers whose usage is read from a per-account directory.
    static let supportedProviders: [ProviderKind] = [.claude, .codex]

    var rootURL: URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    var claudeProjectsDir: URL { rootURL.appendingPathComponent("projects", isDirectory: true) }
    var codexSessionsDir: URL { rootURL.appendingPathComponent("sessions", isDirectory: true) }

    /// Where this account's usage logs live.
    var logsDir: URL { provider == .codex ? codexSessionsDir : claudeProjectsDir }

    var title: String { "\(provider.displayName) · \(name)" }

    /// The root the default account for `provider` reads, for rejecting a
    /// duplicate of it.
    static func defaultRoot(for provider: ProviderKind) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch provider {
        case .codex: return home.appendingPathComponent(".codex", isDirectory: true)
        case .antigravity: return home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        case .claude: return home.appendingPathComponent(".claude", isDirectory: true)
        }
    }

    /// True for ids made only of ASCII letters, digits and dashes — safe to
    /// embed in a filename and in the status-line command line.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-")
        }
    }

    /// Derives an id from the provider and a display name, adding a numeric
    /// suffix until it is unique among `existing`.
    static func makeID(provider: ProviderKind, name: String, existing: Set<String>) -> String {
        let mapped = name.lowercased().unicodeScalars.map { scalar -> Character in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let slug = String(mapped).split(separator: "-").joined(separator: "-")
        let base = "\(provider.rawValue)-\(slug.isEmpty ? "account" : slug)"
        var candidate = base
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}

/// What one extra account currently shows. Only the fields for its provider
/// are filled.
struct AccountReading: Identifiable {
    let account: ExtraAccount
    var claude: ClaudeUsage?
    var claudeLimits: ClaudeLimits?
    var codex: CodexUsage?
    var codexLimits: CodexLimits?

    var id: String { account.id }
}
