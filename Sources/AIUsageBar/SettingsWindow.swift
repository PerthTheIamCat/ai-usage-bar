import AppKit
import SwiftUI
import ServiceManagement

/// Apple-style preferences window: a top tab switcher (the same pattern as
/// Xcode/Mail/Safari Preferences) instead of one long scrolling form, so each
/// page stays short and the Log doesn't crowd out everything else.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ProvidersTab()
                .tabItem { Label("Providers", systemImage: "arrow.up.arrow.down") }
            CostTab()
                .tabItem { Label("Cost", systemImage: "dollarsign.circle") }
            LogTab()
                .tabItem { Label("Log", systemImage: "doc.text") }
            ChangelogTab()
                .tabItem { Label("Changelog", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 620, height: 650)
    }
}

private struct GeneralTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    /// Every provider carries its own style, and those always shadow the
    /// stored default — so a picker bound to the default alone looked broken:
    /// changing it never altered the menu bar. This writes through to all
    /// providers, and reports the shared style when they agree.
    private var allProvidersStyleBinding: Binding<LimitStyle> {
        Binding(
            get: {
                let styles = ProviderKind.allCases.map { settings.limitStyle(for: $0) }
                return styles.dropFirst().allSatisfy { $0 == styles.first } ? (styles.first ?? settings.limitStyle) : settings.limitStyle
            },
            set: { style in
                settings.limitStyle = style
                for kind in ProviderKind.allCases { settings.setLimitStyle(style, for: kind) }
            })
    }

    var body: some View {
        Form {
            Section {
                Picker("Show limits as", selection: $settings.displayMode) {
                    Text("Remaining — “84% left”").tag(UsageDisplayMode.remaining)
                    Text("Used — “16% used”").tag(UsageDisplayMode.used)
                }
                .pickerStyle(.segmented)
                Picker("Menu bar style", selection: allProvidersStyleBinding) {
                    ForEach(LimitStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Usage display")
            } footer: {
                Text("Applies to every provider. Choose a different style for an individual provider in Settings › Providers. The popover always shows the full bar meter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Cache hit rate", isOn: $settings.showCacheHitRate)
                Toggle("Per-model breakdown", isOn: $settings.showModelBreakdown)
                Toggle("Avg/session", isOn: $settings.showAvgPerSession)
                Toggle("7-day / 30-day cost", isOn: $settings.showPeriodCost)
                Toggle("Skills used today", isOn: $settings.showSkillsUsed)
                Toggle("Skills & tools by session", isOn: $settings.showSessionActivity)
            } header: {
                Text("Dropdown content")
            } footer: {
                Text("These are global master switches. Use Settings › Providers for provider-specific detail choices. Limits, today's tokens, and Est. cost always show.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Slider(value: $settings.warnBelowRemaining, in: 5...45, step: 5) {
                    Text("Warn below")
                } minimumValueLabel: {
                    Text("5%")
                } maximumValueLabel: {
                    Text("45%")
                }
                LabeledContent("Current threshold") {
                    Text("turns red at \(Int(settings.warnBelowRemaining))% remaining")
                        .foregroundStyle(.secondary)
                }
                Toggle("Send a notification when a window crosses it", isOn: $settings.notificationsEnabled)
            } header: {
                Text("Low-limit warning")
            } footer: {
                Text("The menu-bar percentage and meters turn red when a window's remaining capacity drops below this. Notifications fire once per crossing (also covers the budget alert on the Cost tab) and still need macOS notification permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Alert on unusually large session", isOn: $settings.sessionAlertEnabled)
                if settings.sessionAlertEnabled {
                    Picker("Token threshold", selection: $settings.sessionAlertThreshold) {
                        ForEach([1_000_000.0, 5_000_000.0, 10_000_000.0, 25_000_000.0], id: \.self) { value in
                            Text("\(formatTokens(Int(value))) tokens").tag(value)
                        }
                    }
                }
            } header: {
                Text("Session alerts")
            } footer: {
                Text("Notifies once per launch when the largest Claude or Codex session crosses the threshold. Tool/skill cost attribution is an estimate split across calls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show session IDs", isOn: $settings.showSessionIdentifiers)
                Toggle("Show workspace names", isOn: $settings.showSessionWorkspace)
            } header: {
                Text("Session privacy")
            } footer: {
                Text("Turning these off hides identifiers and workspace names from the popover and copied reports. Prompt text and tool arguments are never shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Open at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginItemError = nil
                        } catch {
                            loginItemError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProvidersTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Providers").font(.headline)
            Text("Drag to reorder providers. Expand a provider to configure its menu-bar style, limit windows, popover visibility, and detail rows independently.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(settings.providerOrder) { kind in
                    ProviderRow(kind: kind)
                }
                .onMove { settings.moveProvider(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .transaction { transaction in
                // Variable-height rows inside a macOS List can animate their
                // remeasurement and visibly jump while a provider expands.
                transaction.animation = nil
            }
            .frame(minHeight: 360, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(20)
    }
}

private struct ProviderRow: View {
    let kind: ProviderKind
    @ObservedObject private var settings = AppSettings.shared
    @State private var expanded = false

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { settings.isShownInMenuBar(kind) },
            set: { settings.setShownInMenuBar(kind, $0) })
    }

    private var popoverBinding: Binding<Bool> {
        Binding(
            get: { settings.isShownInPopover(kind) },
            set: { settings.setShownInPopover(kind, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    // Keep the List row resize synchronous; animated
                    // variable-height rows visibly jump on macOS.
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .frame(width: 12)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse \(kind.displayName) settings" : "Expand \(kind.displayName) settings")

                Image(nsImage: kind.icon)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(kind.displayName)
                    .font(.system(size: 13, weight: .medium))
                Spacer()

                Toggle("Menu bar", isOn: menuBarBinding)
                    .toggleStyle(.checkbox)
                    .help("Show \(kind.displayName) in the menu bar")
                    .accessibilityLabel("Show \(kind.displayName) in menu bar")
                    .accessibilityValue(settings.isShownInMenuBar(kind) ? "On" : "Off")

                Toggle("Popover", isOn: popoverBinding)
                    .toggleStyle(.checkbox)
                    .help("Show \(kind.displayName) in the popover")
                    .accessibilityLabel("Show \(kind.displayName) in popover")
                    .accessibilityValue(settings.isShownInPopover(kind) ? "On" : "Off")

                Label("Drag", systemImage: "line.3.horizontal")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help("Drag to reorder providers")
                    .accessibilityLabel("Drag to reorder providers")
            }
            .font(.system(size: 11))
            .padding(.vertical, 5)

            if expanded {
                ProviderConfiguration(kind: kind)
                    .padding(.bottom, 8)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ProviderConfiguration: View {
    let kind: ProviderKind
    @ObservedObject private var settings = AppSettings.shared

    private var styleBinding: Binding<LimitStyle> {
        Binding(
            get: { settings.limitStyle(for: kind) },
            set: { settings.setLimitStyle($0, for: kind) })
    }

    private func windowBinding(_ window: LimitWindowKind) -> Binding<Bool> {
        Binding(
            get: { settings.isLimitWindowShown(window, for: kind) },
            set: { settings.setLimitWindowShown(window, for: kind, $0) })
    }

    private func detailBinding(_ detail: ProviderDetailKind) -> Binding<Bool> {
        Binding(
            get: { settings.providerDetails[kind]?.contains(detail) ?? true },
            set: { settings.setDetailShown(detail, for: kind, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            LabeledContent("Menu-bar style") {
                Picker("Menu-bar style", selection: styleBinding) {
                    ForEach(LimitStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150, alignment: .trailing)
            }

            Text("Limit windows")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(kind.supportedLimitWindows) { window in
                Toggle(window.displayName, isOn: windowBinding(window))
                    .toggleStyle(.checkbox)
            }

            Text("Popover details")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            ForEach(kind.supportedDetails) { detail in
                Toggle(detail.displayName, isOn: detailBinding(detail))
                    .toggleStyle(.checkbox)
            }
        }
        .font(.system(size: 12))
        .padding(.leading, 28)
    }
}

private struct CostTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var isRefreshing = false

    private var lastFetchedText: String {
        settings.thbLastFetched.map(humanAgo) ?? "never"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Fetch live rate automatically", isOn: $settings.thbAutoFetch)
                LabeledContent("THB per USD") {
                    TextField("33", value: $settings.thbPerUSD, format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .disabled(settings.thbAutoFetch)
                }
                LabeledContent("Last fetched") {
                    Text(lastFetchedText)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button(isRefreshing ? "Refreshing…" : "Refresh Now") {
                        isRefreshing = true
                        ExchangeRateFetcher.fetchUSDtoTHB { rate in
                            isRefreshing = false
                            if let rate {
                                settings.thbPerUSD = rate
                                settings.thbLastFetched = Date()
                            }
                        }
                    }
                    .disabled(isRefreshing)
                }
            } header: {
                Text("Exchange rate")
            } footer: {
                Text("Cost rows price today's tokens at API list prices, converted to baht at this rate. Auto-fetch pulls from api.frankfurter.app (ECB daily rates); turn it off to set a fixed rate by hand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Enable budget alert", isOn: $settings.budgetEnabled)
                if settings.budgetEnabled {
                    LabeledContent("Amount") {
                        HStack(spacing: 4) {
                            Text("$")
                            TextField("10", value: $settings.budgetAmountUSD, format: .number.precision(.fractionLength(0...2)))
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    Picker("Period", selection: $settings.budgetPeriod) {
                        ForEach(BudgetPeriod.allCases) { period in
                            Text(period.displayName).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text("Budget alert")
            } footer: {
                Text("Warns in the menu bar and the popover once estimated spend crosses 80% of this amount for the period. \"Per 30 days\" is a rolling window, not the calendar month.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LogTab: View {
    @State private var logText = ""
    @State private var copyStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(logText.isEmpty ? "No log entries yet." : logText)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .id("logEnd")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onAppear {
                    logText = AppLog.shared.tail()
                    proxy.scrollTo("logEnd", anchor: .bottom)
                }
            }
            HStack {
                Button("Refresh") { logText = AppLog.shared.tail() }
                Button("Copy Log", systemImage: "doc.on.doc") {
                    let latestLog = AppLog.shared.tail()
                    logText = latestLog
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(latestLog, forType: .string)
                    copyStatus = latestLog.isEmpty ? "No log entries to copy" : "Log copied"
                }
                Button("Open Log File") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppLog.shared.fileURL])
                }
                Spacer()
                if let copyStatus {
                    Text(copyStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Button("Clear", role: .destructive) {
                    AppLog.shared.clear()
                    logText = AppLog.shared.tail()
                    copyStatus = nil
                }
            }
            Text("Local Claude/Codex snapshots, exchange-rate requests, and errors. Stored at ~/Library/Logs/AIUsageBar/.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

private enum ChangelogLine {
    case version(String)
    case section(String)
    case bullet(String)
    case text(String)
    case blank
}

/// Minimal line-based parser for this repo's CHANGELOG.md shape — `## `
/// version headings, `### ` section headings (Added/Fixed/Changed), `- `
/// bullets with two-space-indented wrapped continuations, blank lines as
/// spacing. Not a general Markdown renderer; SwiftUI's `Text` markdown
/// support doesn't style block-level headings the way this needs.
private func parseChangelog(_ raw: String) -> [ChangelogLine] {
    var result: [ChangelogLine] = []
    for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("## ") {
            result.append(.version(String(line.dropFirst(3))))
        } else if line.hasPrefix("### ") {
            result.append(.section(String(line.dropFirst(4))))
        } else if line.hasPrefix("- ") {
            result.append(.bullet(String(line.dropFirst(2))))
        } else if line.hasPrefix("# ") {
            continue // skip the top-level "# Changelog" title; the tab already has one
        } else if trimmed.isEmpty {
            result.append(.blank)
        } else if line.hasPrefix("  "), case .bullet(let prev)? = result.last {
            result[result.count - 1] = .bullet(prev + " " + trimmed)
        } else {
            result.append(.text(trimmed))
        }
    }
    return result
}

private struct ChangelogTab: View {
    @State private var lines: [ChangelogLine] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    switch line {
                    case .version(let v):
                        Text(v)
                            .font(.system(size: 14, weight: .bold))
                            .padding(.top, 10)
                    case .section(let s):
                        Text(s)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    case .bullet(let b):
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(b).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 12))
                    case .text(let t):
                        Text(t)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    case .blank:
                        Color.clear.frame(height: 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            lines = [.text("Changelog not found in this build.")]
            return
        }
        lines = parseChangelog(text)
    }
}

/// Lazily-created, reusable settings window for this menu-bar-only app.
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: hosting)
            w.title = "AI Usage Bar Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
