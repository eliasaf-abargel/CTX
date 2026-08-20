import CTXCore
import SwiftUI

/// A named subset of rows to narrow a resource screen down to.
///
/// One mechanism for every "N pods need attention" affordance in the workspace: a
/// summary states a number, clicking it opens the list showing exactly the rows that
/// were counted, and a chip above the table says what is being shown and clears it.
/// Without this a panel could only navigate — it announced "3 pods" and then handed
/// over all eighty, leaving the user to work out which three it meant.
struct ResourceFocus: Equatable {
    let section: ClusterWorkspaceSection
    /// Shown on the chip, e.g. "Using ≥90% of their memory limit".
    let title: String
    /// Row ids to keep. Pod rows are keyed `namespace/name`, which is also how
    /// `kubectl top` identifies them, so the two line up without translation.
    let ids: Set<String>

    func matches(_ row: KubernetesResourceRow) -> Bool {
        ids.contains(row.id)
    }
}

/// The chip that shows an active focus and clears it.
struct ResourceFocusChip: View {
    let focus: ResourceFocus
    let matchCount: Int
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(.orange)
            Text(focus.title)
                .font(.system(size: 12, weight: .semibold))
            Text(matchCount == 1 ? "1 match" : "\(matchCount) matches")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(action: clear) {
                Label("Show all", systemImage: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Clear the filter and show every row again")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        }
    }
}
