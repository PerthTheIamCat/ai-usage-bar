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
            AccountsTab()
                .tabItem { Label("Accounts", systemImage: "person.2") }
            CostTab()
                .tabItem { Label("Cost", systemImage: "dollarsign.circle") }
            LogTab()
                .tabItem { Label("Log", systemImage: "doc.text") }
            ChangelogTab()
                .tabItem { Label("Changelog", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 620, height: 750)
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
    private func warnOverrideBinding(_ kind: ProviderKind, _ window: LimitWindowKind) -> Binding<Double?> {
        Binding(
            get: { settings.warnBelowOverride(kind, window) },
            set: { settings.setWarnBelowOverride($0, kind, window) }
        )
    }

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

    private var allProvidersWindowSelection: Binding<MenuBarWindowSelection> {
        Binding(
            get: {
                let selections = ProviderKind.allCases.map { MenuBarWindowSelection.selection(for: $0, in: settings) }
                guard let first = selections.first, selections.dropFirst().allSatisfy({ $0 == first }) else {
                    return .both
                }
                return first
            },
            set: { selection in
                for kind in ProviderKind.allCases {
                    settings.setLimitWindowShown(.fiveHour, for: kind,
                                                  selection == .fiveHour || selection == .both)
                    settings.setLimitWindowShown(.weekly, for: kind,
                                                  selection == .weekly || selection == .both)
                }
                // Keep the legacy Claude-only values in sync for older saved preferences.
                settings.showFiveHourInMenuBar = selection == .fiveHour || selection == .both
                settings.showWeeklyInMenuBar = selection == .weekly || selection == .both
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
                Text("Menu bar style")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ], spacing: 8) {
                    ForEach(LimitStyle.allCases) { style in
                        MenuBarStyleOption(
                            style: style,
                            selected: allProvidersStyleBinding.wrappedValue == style,
                            mode: settings.displayMode,
                            warnBelow: settings.warnBelowRemaining,
                            action: { allProvidersStyleBinding.wrappedValue = style }
                        )
                    }
                }

                Text("Rows to show")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Picker("Rows to show", selection: allProvidersWindowSelection) {
                    ForEach(MenuBarWindowSelection.allCases) { selection in
                        Text(selection.title).tag(selection)
                    }
                }
                .pickerStyle(.segmented)
                .help("Choose whether the menu bar shows the 5-hour row, weekly row, both, or neither.")
            } header: {
                Text("Usage display")
            } footer: {
                Text("Applies to every provider. A single row grows to use the available menu-bar height. The popover always shows the full bar meter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Hardware status")
                    Spacer()
                    if TouchBarHardware.hasPhysicalTouchBar {
                        Label("Touch Bar detected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not detected (\(TouchBarHardware.modelDisplayName))", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Show in Touch Bar (Control Strip)", isOn: $settings.touchBarEnabled)
                    .disabled(!TouchBarHardware.hasPhysicalTouchBar && !settings.forceTouchBarSupport)

                if !TouchBarHardware.hasPhysicalTouchBar {
                    Toggle("Enable anyway (for Touch Bar simulator or virtual tools)", isOn: $settings.forceTouchBarSupport)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Touch Bar")
            } footer: {
                Text(TouchBarHardware.hasPhysicalTouchBar
                     ? "Displays live AI provider meters in the Touch Bar Control Strip next to system controls."
                     : "This Mac (\(TouchBarHardware.modelDisplayName)) does not have a physical Touch Bar. You can enable it anyway if using Xcode Touch Bar Simulator or third-party virtual Touch Bar tools.")
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
                DisclosureGroup("Per-window thresholds") {
                    ForEach(ProviderKind.allCases) { kind in
                        ForEach(kind.supportedLimitWindows) { window in
                            Picker("\(kind.displayName) \(window.displayName.lowercased())", selection: warnOverrideBinding(kind, window)) {
                                Text("Global (\(Int(settings.warnBelowRemaining))%)").tag(Double?.none)
                                ForEach(Array(stride(from: 5.0, through: 45.0, by: 5.0)), id: \.self) { value in
                                    Text("\(Int(value))%").tag(Double?.some(value))
                                }
                            }
                        }
                    }
                }
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

private enum MenuBarWindowSelection: String, CaseIterable, Identifiable {
    case fiveHour
    case weekly
    case both
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveHour: return "5h"
        case .weekly: return "W"
        case .both: return "Both"
        case .none: return "None"
        }
    }

    var description: String {
        switch self {
        case .fiveHour: return "5-hour row only"
        case .weekly: return "Weekly row only"
        case .both: return "5-hour and weekly rows"
        case .none: return "Hide limit rows"
        }
    }

    static func selection(for kind: ProviderKind, in settings: AppSettings) -> Self {
        let fiveHour = settings.isLimitWindowShown(.fiveHour, for: kind)
        let weekly = settings.isLimitWindowShown(.weekly, for: kind)
        switch (fiveHour, weekly) {
        case (true, true): return .both
        case (true, false): return .fiveHour
        case (false, true): return .weekly
        case (false, false): return .none
        }
    }
}

private struct MenuBarStyleOption: View {
    let style: LimitStyle
    let selected: Bool
    let mode: UsageDisplayMode
    let warnBelow: Double
    let action: () -> Void

    private var subtitle: String {
        switch style {
        case .bar: return "Two rows of meters"
        case .ring: return "Two concentric rings"
        case .percentOnly: return "Numbers only"
        case .barAndPercent: return "Meters + values"
        case .ringAndPercent: return "Rings + values"
        case .dotAndPercent: return "Dots + values"
        case .blocks: return "Segmented level blocks"
        case .blocksAndPercent: return "Blocks + values"
        case .battery: return "Battery gauge"
        case .batteryAndPercent: return "Battery + values"
        case .pill: return "Inline pill badge"
        }
    }

    private var preview: NSImage {
        MiniMeter.image(
            windows: [
                MenuBarWindow(kind: .fiveHour, remainingPercent: 58),
                MenuBarWindow(kind: .weekly, remainingPercent: 82)
            ],
            style: style,
            mode: mode,
            warnBelow: warnBelow
        )
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .font(.system(size: 14))
                Image(nsImage: preview)
                    .interpolation(.high)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 78, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(style.displayName)
                        .font(.system(size: 11, weight: .medium))
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Menu bar style \(style.displayName)")
        .accessibilityValue(selected ? "Selected" : "")
    }
}

private struct ProvidersTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Providers").font(.headline)
            Text("Drag to reorder providers. Expand a provider to configure its menu-bar visibility, popover visibility, and detail rows.")
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

    private struct DataSource: Identifiable {
        let id: String
        let title: String
        let url: URL
        let note: String
    }

    private var dataSources: [DataSource] {
        switch kind {
        case .claude:
            return [
                DataSource(
                    id: "claude-cli-logs",
                    title: "Claude Code · usage logs",
                    url: UsageReader.claudeDir,
                    note: "CLI sessions"),
                DataSource(
                    id: "claude-desktop-usage",
                    title: "Claude Desktop · usage samples",
                    url: ClaudeLimitsReader.desktopPlanUsageURL,
                    note: "Desktop app limits"),
                DataSource(
                    id: "claude-cli-limits",
                    title: "Claude Code · rate limits",
                    url: ClaudeLimitsReader.statusLineSnapshotURL,
                    note: "CLI status line"),
            ]
        case .codex:
            return [
                DataSource(
                    id: "codex-cli-logs",
                    title: "Codex · usage logs",
                    url: UsageReader.codexDir,
                    note: "CLI sessions"),
            ]
        case .antigravity:
            return [
                DataSource(
                    id: "antigravity-cli-history",
                    title: "Antigravity CLI · activity",
                    url: UsageReader.antigravityDir.appendingPathComponent("history.jsonl"),
                    note: "CLI history"),
                DataSource(
                    id: "antigravity-ide-conversations",
                    title: "Antigravity IDE · activity",
                    url: UsageReader.antigravityIDEDir.appendingPathComponent("conversations"),
                    note: "Desktop app conversations"),
                DataSource(
                    id: "antigravity-cli-limits",
                    title: "Antigravity CLI · quota snapshot",
                    url: AntigravityLimitsReader.statusLineSnapshotURL,
                    note: "CLI status line"),
            ]
        }
    }

    private var capabilityDescription: String {
        switch kind {
        case .claude:
            return "Claude Desktop provides usage percentages; CLI status line adds reset times when available."
        case .codex:
            return "Reads local Codex CLI session logs."
        case .antigravity:
            return "Reads CLI and IDE activity; quota is available from the CLI status line."
        }
    }

    private func displayPath(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    private func revealInFinder(_ url: URL) {
        let fileManager = FileManager.default
        let target = fileManager.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func detailBinding(_ detail: ProviderDetailKind) -> Binding<Bool> {
        Binding(
            get: { settings.providerDetails[kind]?.contains(detail) ?? true },
            set: { settings.setDetailShown(detail, for: kind, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Data sources")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text(capabilityDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ForEach(dataSources) { source in
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(source.title)
                            if !FileManager.default.fileExists(atPath: source.url.path) {
                                Text("Not found")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text("\(source.note) · \(displayPath(for: source.url))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Button {
                        revealInFinder(source.url)
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal \(source.title) in Finder")
                }
            }

            Divider()
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
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
