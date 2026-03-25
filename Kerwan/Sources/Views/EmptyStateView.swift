import SwiftUI

/// A standardised empty-state view used consistently across all Kerwan sections.
///
/// Each section that has no data yet renders this view with a section-appropriate
/// icon, a short title, and a subtitle explaining what will appear once capture
/// begins. An optional call-to-action button can trigger a first-run action.
///
/// Design language: muted, non-intrusive. Uses `.tertiary` foreground so the
/// empty state recedes visually and does not compete with the sidebar.
struct EmptyStateView: View {
    /// SF Symbol name for the large icon.
    let icon: String

    /// Primary message (title weight, secondary color).
    let title: String

    /// Supporting description (caption weight, tertiary color).
    let subtitle: String

    /// Optional button label. When non-nil an outlined button appears below
    /// the subtitle.
    var actionLabel: String? = nil

    /// Action invoked when the button is tapped. Ignored if `actionLabel` is nil.
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 20) {
                // Icon
                Image(systemName: icon)
                    .font(.system(size: 56, weight: .ultraLight))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tertiary)

                // Text stack
                VStack(spacing: 6) {
                    Text(title)
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Optional CTA
                if let label = actionLabel {
                    Button(label) { action?() }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
