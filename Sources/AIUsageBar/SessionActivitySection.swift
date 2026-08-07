import SwiftUI

/// Today's sessions, newest first. The popover deliberately shows only the
/// three most recent — it exists to answer "how much is left", not to be a
/// session browser. The full list is still available through Export.
struct SessionActivitySection: View {
    let title: String
    let sessions: [SessionActivity]

    private let limit = 3

    private var displayedSessions: [SessionActivity] {
        Array(sessions.prefix(limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) · \(sessions.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(displayedSessions) { session in
                    SessionActivityRow(session: session)
                }
            }

            if sessions.count > limit {
                Text("Showing the 3 most recent of \(sessions.count) — Export for the full list")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
