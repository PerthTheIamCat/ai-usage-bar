import SwiftUI

struct SessionActivityRow: View {
    let session: SessionActivity
    @ObservedObject private var settings = AppSettings.shared
    @State private var isExpanded = false

    private var explicitName: String? {
        guard let name = session.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        return name
    }

    private var visibleWorkspace: String? {
        guard settings.showSessionWorkspace,
              let workspace = session.workspace?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspace.isEmpty
        else { return nil }
        return workspace
    }

    private var shortID: String {
        String(session.id.prefix(12))
    }

    private var title: String {
        if let explicitName { return explicitName }
        if let visibleWorkspace { return visibleWorkspace }
        if settings.showSessionIdentifiers { return "Session \(shortID)" }
        return "Unnamed session"
    }

    private var timeText: String {
        session.lastActivityAt?.formatted(date: .omitted, time: .shortened) ?? "—"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            details
        } label: {
            summary
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: explicitName == nil ? "rectangle.stack" : "text.bubble")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(timeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                if explicitName != nil, let visibleWorkspace {
                    Text(visibleWorkspace)
                }
                if let model = session.model, !model.isEmpty {
                    Text(model)
                }
                if settings.showSessionIdentifiers, explicitName != nil || visibleWorkspace != nil {
                    Text("ID \(shortID)")
                        .monospaced()
                }
                Text("· \(formatTokens(session.tokenTotal)) tokens")
                if session.estimatedCostUSD > 0 {
                    Text("· \(formatUSD(session.estimatedCostUSD))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !session.skills.isEmpty {
                ActivityBreakdown(
                    title: session.inferredSkills.isEmpty ? "Skills" : "Skills (inferred)",
                    counts: session.skills,
                    costs: session.skillCosts)
            }
            if !session.tools.isEmpty {
                ActivityBreakdown(title: "Tools", counts: session.tools, costs: session.toolCosts)
            }
            if session.skills.isEmpty && session.tools.isEmpty {
                NoteText(text: "No Skill/tool calls recorded")
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}

/// One aligned row per skill/tool instead of a single comma-joined paragraph
/// — the flowing text wrapped mid-entry and made counts and costs impossible
/// to compare down the column. Only the heaviest few are listed; the full set
/// is in the exports.
private struct ActivityBreakdown: View {
    let title: String
    let counts: [String: Int]
    let costs: [String: Double]

    private let limit = 5

    private struct Entry: Identifiable {
        let name: String
        let count: Int
        let cost: Double
        var id: String { name }
    }

    private var ranked: [Entry] {
        var entries: [Entry] = []
        entries.reserveCapacity(counts.count)
        for (name, count) in counts {
            entries.append(Entry(name: name, count: count, cost: costs[name] ?? 0))
        }
        entries.sort { lhs, rhs in
            lhs.count == rhs.count ? lhs.name < rhs.name : lhs.count > rhs.count
        }
        return entries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("est. cost")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ForEach(ranked.prefix(limit)) { item in
                HStack(spacing: 8) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("×\(item.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                    Text(item.cost > 0 ? "~\(formatUSD(item.cost))" : "—")
                        .monospacedDigit()
                        .frame(width: 62, alignment: .trailing)
                }
                .font(.caption)
            }

            if ranked.count > limit {
                Text("+\(ranked.count - limit) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
