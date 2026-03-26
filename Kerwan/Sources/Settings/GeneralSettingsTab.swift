import SwiftUI

/// General settings tab — capture toggles, consent, launch-at-login,
/// daily digest time, and default billing rate.
@MainActor
struct GeneralSettingsTab: View {
    @Bindable var vm: SettingsViewModel

    var body: some View {
        Form {
            captureSection
            billingSection
            scheduleSection
            startupSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Capture

    private var captureSection: some View {
        Section {
            Toggle("Capture audio", isOn: $vm.captureAudio)
                .onChange(of: vm.captureAudio) { _, v in
                    vm.saveSetting(key: "captureAudio", value: v)
                }

            Toggle("Track app focus (Accessibility)", isOn: $vm.captureAccessibility)
                .onChange(of: vm.captureAccessibility) { _, v in
                    vm.saveSetting(key: "captureAccessibility", value: v)
                }

            Toggle("Consent mode", isOn: $vm.consentMode)
                .onChange(of: vm.consentMode) { _, v in
                    vm.saveSetting(key: "consentMode", value: v)
                }
        } header: {
            Text("Capture")
        } footer: {
            Text("Consent mode pauses all capture and classification until re-enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Billing

    private var billingSection: some View {
        Section("Billing") {
            LabeledContent("Default hourly rate") {
                HStack(spacing: 4) {
                    Text("$")
                        .foregroundStyle(.secondary)
                    TextField(
                        "150",
                        value: $vm.billableDefaultRate,
                        format: .number.precision(.fractionLength(2))
                    )
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: vm.billableDefaultRate) { _, v in
                        vm.saveSetting(key: "billableDefaultRate", value: v)
                    }
                    Text("/ hr")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Schedule

    private var scheduleSection: some View {
        Section("Daily Digest") {
            DatePicker(
                "Send digest at",
                selection: $vm.digestTime,
                displayedComponents: .hourAndMinute
            )
            .onChange(of: vm.digestTime) { _, _ in
                vm.saveDigestTime()
            }
        }
    }

    // MARK: - Startup

    private var startupSection: some View {
        Section("Startup") {
            Toggle("Launch at login", isOn: $vm.launchAtLogin)
                .onChange(of: vm.launchAtLogin) { _, _ in
                    vm.toggleLaunchAtLogin()
                }

            Toggle("Store passphrase in Keychain", isOn: $vm.passphraseInKeychain)
                .onChange(of: vm.passphraseInKeychain) { _, v in
                    vm.saveSetting(key: "passphraseInKeychain", value: v)
                }
        }
    }
}
