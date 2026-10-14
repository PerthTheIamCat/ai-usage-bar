import AppKit
import SwiftUI

/// Settings → Accounts: add extra Claude Code / Codex accounts, each read
/// from its own config folder.
struct AccountsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var provider: ProviderKind = .claude
    @State private var name = ""
    @State private var path = ""
    @State private var errorMessage: String?

    private var placeholderPath: String {
        provider == .codex ? "~/.codex-work" : "~/.claude-work"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accounts").font(.headline)
            Text("The default Claude Code (~/.claude) and Codex (~/.codex) accounts are always shown. To track another account, give it its own config folder — start Claude Code with CLAUDE_CONFIG_DIR=~/.claude-work or Codex with CODEX_HOME=~/.codex-work — then add that folder here. Extra accounts appear under “Other accounts” in the popover.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                if settings.extraAccounts.isEmpty {
                    Text("No extra accounts yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.extraAccounts) { account in
                    AccountRow(account: account)
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 200, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            GroupBox("Add account") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Provider", selection: $provider) {
                        ForEach(ExtraAccount.supportedProviders) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Name (for example Work)", text: $name)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        TextField("Config folder (\(placeholderPath))", text: $path)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { chooseFolder() }
                    }

                    HStack {
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Add") { add() }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                      || path.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(6)
            }
        }
        .padding(20)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            path = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    private func add() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedPath = path.trimmingCharacters(in: .whitespaces)
        let resolved = URL(fileURLWithPath: (trimmedPath as NSString).expandingTildeInPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            errorMessage = "That folder doesn't exist."
            return
        }
        if resolved.path == ExtraAccount.defaultRoot(for: provider).standardizedFileURL.path {
            errorMessage = "That's the default account, which is always shown."
            return
        }
        let duplicate = settings.extraAccounts.contains {
            $0.provider == provider && $0.rootURL.standardizedFileURL.path == resolved.path
        }
        if duplicate {
            errorMessage = "That folder is already added."
            return
        }
        errorMessage = nil
        settings.addAccount(
            provider: provider, name: trimmedName,
            path: (resolved.path as NSString).abbreviatingWithTildeInPath)
        name = ""
        path = ""
    }
}

private struct AccountRow: View {
    let account: ExtraAccount
    @ObservedObject private var settings = AppSettings.shared
    @State private var setupState: ClaudeStatusLineSetup.State
    @State private var resultMessage: String?
    @State private var resultIsError = false

    init(account: ExtraAccount) {
        self.account = account
        _setupState = State(initialValue: ClaudeStatusLineSetup.currentState(for: account))
    }

    private var folderExists: Bool {
        FileManager.default.fileExists(atPath: account.rootURL.path)
    }

    private func installBridge() {
        switch ClaudeStatusLineSetup.install(for: account) {
        case .success:
            resultMessage = "Status line installed. Restart Claude Code in this account, then send a message to get a reading."
            resultIsError = false
            setupState = ClaudeStatusLineSetup.currentState(for: account)
        case .failure(let error):
            resultMessage = error.message(settingsPath: ClaudeStatusLineSetup.settingsDisplayPath(for: account))
            resultIsError = true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(nsImage: account.provider.icon)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.title).font(.system(size: 13, weight: .medium))
                    Text(account.path + (folderExists ? "" : " · not found"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if account.provider == .claude, setupState == .notConfigured {
                    Button("Set Up Status Line") { installBridge() }
                        .font(.system(size: 11))
                }
                Button("Remove") { settings.removeAccount(id: account.id) }
                    .font(.system(size: 11))
            }
            if account.provider == .claude, setupState == .configured, resultMessage == nil {
                Text("Status line installed — limits appear after Claude Code runs in this account.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let resultMessage {
                Text(resultMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(resultIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}
