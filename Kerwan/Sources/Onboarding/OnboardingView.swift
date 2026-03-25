import SwiftUI

// MARK: - OnboardingView

/// The root view rendered inside the onboarding window.
///
/// Manages a 5-step flow:
/// 1. **Welcome** — brand intro + "Get Started"
/// 2. **Permissions** — one-at-a-time requests with live checkmarks
/// 3. **Email** — Gmail OAuth connection (skippable)
/// 4. **AI Setup** — Whisper + Ollama model download with progress bars
/// 5. **Ready** — completion screen + "Open Kerwan"
///
/// Navigation is driven by `OnboardingViewModel`. Each step slides in/out
/// using an asymmetric transition keyed to `vm.isAnimatingForward`.
struct OnboardingView: View {
    @Bindable var vm: OnboardingViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Step dots
            stepDotsBar
                .padding(.top, 28)

            // Step content — keyed to `currentStep` so SwiftUI treats each
            // step as a distinct view and runs the transition.
            Group {
                switch vm.currentStep {
                case .welcome:     WelcomeStep(vm: vm)
                case .permissions: PermissionsStep(vm: vm)
                case .email:       EmailStep(vm: vm)
                case .aiSetup:     AISetupStep(vm: vm)
                case .ready:       ReadyStep(vm: vm)
                }
            }
            .id(vm.currentStep)
            .transition(
                .asymmetric(
                    insertion: .move(edge: vm.isAnimatingForward ? .trailing : .leading)
                        .combined(with: .opacity),
                    removal: .move(edge: vm.isAnimatingForward ? .leading : .trailing)
                        .combined(with: .opacity)
                )
            )
            .animation(.easeInOut(duration: 0.28), value: vm.currentStep)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation buttons
            navigationBar
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
        }
        .frame(width: 600, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Step dots

    private var stepDotsBar: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                Circle()
                    .fill(step == vm.currentStep ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: step == vm.currentStep ? 8 : 6,
                           height: step == vm.currentStep ? 8 : 6)
                    .animation(.easeInOut(duration: 0.2), value: vm.currentStep)
            }
        }
        .accessibilityLabel(
            "Step \(vm.currentStep.rawValue + 1) of \(OnboardingStep.allCases.count)"
        )
    }

    // MARK: - Navigation bar

    @ViewBuilder
    private var navigationBar: some View {
        HStack {
            // Back button (hidden on first and last step)
            if vm.currentStep != .welcome && vm.currentStep != .ready {
                Button("Back") { vm.goBack() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else {
                Color.clear.frame(width: 40, height: 1)
            }

            Spacer()

            // Skip button (only for skippable steps)
            if vm.currentStep.isSkippable {
                Button("Skip") { vm.skip() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 12)
            }

            // Primary continue / finish button
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch vm.currentStep {
        case .welcome:
            Button("Get Started") { withAnimation { vm.advance() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

        case .permissions:
            Button("Continue") { withAnimation { vm.advance() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

        case .email:
            Button("Continue") { withAnimation { vm.advance() } }
                .buttonStyle(.borderedProminent)
                .disabled(false)  // always enabled; skip is separate
                .keyboardShortcut(.defaultAction)

        case .aiSetup:
            Button("Continue") { withAnimation { vm.advance() } }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isDownloading)
                .keyboardShortcut(.defaultAction)

        case .ready:
            Button("Open Kerwan") { vm.complete() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    let vm: OnboardingViewModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.tint)
                .padding(.top, 24)

            VStack(spacing: 10) {
                Text("Welcome to Kerwan")
                    .font(.largeTitle.bold())

                Text("Your intelligent billing and relationship\nmemory — running privately on your Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 32) {
                FeaturePill(icon: "mic.fill",     label: "Auto-tracks meetings")
                FeaturePill(icon: "dollarsign",   label: "Bills automatically")
                FeaturePill(icon: "lock.fill",    label: "100% local & private")
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 48)
    }
}

private struct FeaturePill: View {
    let icon: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 110)
    }
}

// MARK: - Step 2: Permissions

private struct PermissionsStep: View {
    @Bindable var vm: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "hand.raised.fill",
                title: "System Permissions",
                subtitle: "Kerwan needs a few permissions to track your work automatically. You can grant them now or later in Settings."
            )

            VStack(spacing: 10) {
                ForEach(vm.permissions) { item in
                    OnboardingPermissionRow(item: item) {
                        Task { await vm.requestPermission(item) }
                    }
                }
            }
            .padding(.horizontal, 28)

            // Polling so the user sees checkmarks appear after granting in System Settings
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    vm.refreshPermissions()
                }
            }
        }
        .padding(.top, 20)
    }
}

private struct OnboardingPermissionRow: View {
    let item: OnboardingPermissionItem
    let onRequest: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.id.systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.id.title)
                    .font(.subheadline.bold())
                Text(item.id.permissionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            statusView
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusView: some View {
        switch item.status {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
        case .denied:
            Button("Open Settings") {
                NSWorkspace.shared.open(item.id.settingsURL)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        default:
            Button("Allow") { onRequest() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Step 3: Email

private struct EmailStep: View {
    @Bindable var vm: OnboardingViewModel

    var body: some View {
        VStack(spacing: 28) {
            stepHeader(
                icon: "envelope.fill",
                title: "Connect Your Email",
                subtitle: "Link Gmail to automatically surface email threads in meeting briefs and invoice histories."
            )

            if vm.gmailConnected {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                    Text("Gmail connected")
                        .font(.headline)
                }
                .padding(16)
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Button {
                    vm.connectGmail()
                } label: {
                    HStack(spacing: 10) {
                        if vm.isConnectingGmail {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "envelope.badge.shield.half.filled.fill")
                        }
                        Text(vm.isConnectingGmail ? "Connecting…" : "Connect Gmail")
                            .fontWeight(.semibold)
                    }
                    .frame(width: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(vm.isConnectingGmail)
            }

            Text("Kerwan only reads headers and metadata — never email bodies — and all data stays on your Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(.horizontal, 48)
    }
}

// MARK: - Step 4: AI Setup

private struct AISetupStep: View {
    @Bindable var vm: OnboardingViewModel

    var body: some View {
        VStack(spacing: 24) {
            stepHeader(
                icon: "cpu.fill",
                title: "Setting Up AI Models",
                subtitle: "Kerwan uses on-device AI for transcription and digest generation — no data ever leaves your Mac."
            )

            VStack(spacing: 14) {
                ModelDownloadRow(
                    name: "Whisper (Speech Recognition)",
                    detail: "~150 MB · Used for meeting transcription",
                    progress: vm.whisperProgress,
                    isComplete: vm.whisperComplete,
                    isWaiting: !vm.isDownloading && !vm.whisperComplete
                )
                ModelDownloadRow(
                    name: "Ollama (Language Model)",
                    detail: "~4 GB · Used for digests and summaries",
                    progress: vm.ollamaProgress,
                    isComplete: vm.ollamaComplete,
                    isWaiting: !vm.whisperComplete
                )
            }
            .padding(.horizontal, 36)

            if !vm.isDownloading && !vm.downloadComplete {
                Button("Download Models") {
                    vm.startModelDownload()
                }
                .buttonStyle(.borderedProminent)
            }

            if let error = vm.downloadError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 28)
    }
}

private struct ModelDownloadRow: View {
    let name: String
    let detail: String
    let progress: Double
    let isComplete: Bool
    let isWaiting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline.bold())
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if isWaiting {
                    Text("Waiting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if !isWaiting {
                ProgressView(value: isComplete ? 1.0 : progress)
                    .progressViewStyle(.linear)
                    .animation(.linear(duration: 0.15), value: progress)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Step 5: Ready

private struct ReadyStep: View {
    let vm: OnboardingViewModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.green)
                .padding(.top, 24)

            VStack(spacing: 10) {
                Text("You're all set!")
                    .font(.largeTitle.bold())

                Text("Kerwan is capturing in the background.\nOpen the main window any time via the menu bar icon.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Surface any skipped steps so the user knows what to revisit
            if vm.permissionsSkipped || vm.emailSkipped || vm.aiSetupSkipped {
                VStack(alignment: .leading, spacing: 6) {
                    Text("You can complete these in Settings later:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    if vm.permissionsSkipped {
                        SkippedBadge(label: "System Permissions")
                    }
                    if vm.emailSkipped {
                        SkippedBadge(label: "Gmail Connection")
                    }
                    if vm.aiSetupSkipped {
                        SkippedBadge(label: "AI Model Download")
                    }
                }
                .padding(14)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 48)
    }
}

private struct SkippedBadge: View {
    let label: String

    var body: some View {
        Label(label, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}

// MARK: - Shared helpers

/// Standard header layout reused across steps.
private func stepHeader(icon: String, title: String, subtitle: String) -> some View {
    VStack(spacing: 10) {
        Image(systemName: icon)
            .font(.system(size: 40))
            .foregroundStyle(.tint)

        Text(title)
            .font(.title.bold())

        Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
    }
    .padding(.horizontal, 28)
}
