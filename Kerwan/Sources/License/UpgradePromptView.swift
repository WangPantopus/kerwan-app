import SwiftUI
import KerwanKeychain

/// A view shown when a free-tier user attempts to access a paid feature.
///
/// Present as a `.sheet` or inline overlay. The view self-dismisses via the
/// SwiftUI `dismiss` environment value, so it works in both modal and sheet
/// contexts.
///
/// ```swift
/// .sheet(isPresented: $showUpgrade) {
///     UpgradePromptView(feature: .llm, licenseManager: licenseManager)
/// }
/// ```
struct UpgradePromptView: View {

    // MARK: - Paid Feature Catalogue

    /// The paid features that can trigger an upgrade prompt.
    enum PaidFeature: Sendable {
        case llm
        case unlimitedHistory
        case crmExport
        case teamSharing

        var systemImageName: String {
            switch self {
            case .llm:              return "cpu"
            case .unlimitedHistory: return "clock.arrow.circlepath"
            case .crmExport:        return "square.and.arrow.up"
            case .teamSharing:      return "person.2"
            }
        }

        var title: String {
            switch self {
            case .llm:              return "AI Classification"
            case .unlimitedHistory: return "Unlimited History"
            case .crmExport:        return "CRM Export"
            case .teamSharing:      return "Team Sharing"
            }
        }

        var description: String {
            switch self {
            case .llm:
                return "Auto-classify interactions, extract promises, and generate "
                     + "semantic embeddings — all processed locally with Ollama."
            case .unlimitedHistory:
                return "Keep your complete capture history forever. "
                     + "Free accounts retain the last 30 days of activity."
            case .crmExport:
                return "Export contacts and interaction history to CSV or push directly "
                     + "to HubSpot."
            case .teamSharing:
                return "Share client timelines, billing sessions, and relationship "
                     + "memory across your team."
            }
        }

        /// The plan name required to unlock this feature.
        var requiredPlan: String {
            switch self {
            case .llm, .unlimitedHistory, .crmExport: return "Pro"
            case .teamSharing:                         return "Team"
            }
        }
    }

    // MARK: - Properties

    /// The feature the user tried to access.
    let feature: PaidFeature

    /// The license manager — used to open the purchase page.
    let licenseManager: LicenseManager

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ────────────────────────────────────────────────────
            VStack(spacing: 12) {
                Image(systemName: feature.systemImageName)
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.secondary)
                    .padding(.top, 28)

                Text(feature.title)
                    .font(.title2.weight(.semibold))

                Text("Requires \(feature.requiredPlan) plan")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            Divider()
                .padding(.vertical, 20)

            // ── Description ───────────────────────────────────────────────
            Text(feature.description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 28)

            // ── Actions ───────────────────────────────────────────────────
            VStack(spacing: 10) {
                Button {
                    dismiss()
                    Task { await licenseManager.openPurchasePage() }
                } label: {
                    Text("Upgrade to \(feature.requiredPlan)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button("Not Now", role: .cancel) { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .frame(width: 360, height: 340)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("LLM") {
    // Preview wires a real KeychainManager; the LicenseManager state is default free-tier.
    UpgradePromptView(
        feature: .llm,
        licenseManager: LicenseManager(
            keychain: KeychainManager(service: "com.kerwan.preview")
        )
    )
}

#Preview("Unlimited History") {
    UpgradePromptView(
        feature: .unlimitedHistory,
        licenseManager: LicenseManager(
            keychain: KeychainManager(service: "com.kerwan.preview")
        )
    )
}
#endif
