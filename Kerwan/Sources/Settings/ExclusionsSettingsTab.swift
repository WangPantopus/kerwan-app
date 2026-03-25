import SwiftUI

/// Exclusions tab — lets the user add and remove rules that suppress capture
/// for specific apps, domains, contacts, or window-title regex patterns.
struct ExclusionsSettingsTab: View {
    @Bindable var vm: SettingsViewModel

    var body: some View {
        Form {
            ForEach(ExclusionRuleType.allCases, id: \.self) { ruleType in
                ExclusionSection(vm: vm, ruleType: ruleType)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - ExclusionSection

/// One collapsible section per `ExclusionRuleType`.
private struct ExclusionSection: View {
    @Bindable var vm: SettingsViewModel
    let ruleType: ExclusionRuleType

    /// Tracks the new-rule text field for this section.
    @State private var newPattern: String = ""
    @State private var isRegexInvalid: Bool = false

    private var rulesForType: [ExclusionRule] {
        vm.exclusionRules.filter { $0.ruleType == ruleType }
    }

    var body: some View {
        Section {
            // Existing rules
            ForEach(rulesForType) { rule in
                HStack {
                    Image(systemName: ruleType.systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(rule.pattern)
                        .lineLimit(1)
                    Spacer()
                }
            }
            .onDelete { offsets in
                vm.deleteExclusionRules(ruleType: ruleType, at: offsets)
            }

            // Add-rule row
            HStack(spacing: 8) {
                TextField(ruleType.placeholder, text: $newPattern)
                    .onSubmit { submitNewRule() }
                    .overlay(alignment: .trailing) {
                        if ruleType == .windowTitleRegex && !newPattern.isEmpty {
                            Image(systemName: isRegexInvalid ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(isRegexInvalid ? Color.red : Color.green)
                                .padding(.trailing, 4)
                        }
                    }
                    .onChange(of: newPattern) { _, pattern in
                        if ruleType == .windowTitleRegex {
                            isRegexInvalid = !pattern.isEmpty && !vm.isValidRegex(pattern)
                        }
                    }

                Button("Add") { submitNewRule() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(newPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRegexInvalid)
            }
        } header: {
            Text(ruleType.title)
        } footer: {
            Text(ruleType.footerDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func submitNewRule() {
        let trimmed = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRegexInvalid else { return }
        vm.addExclusionRule(ruleType: ruleType, pattern: trimmed)
        newPattern = ""
    }
}

// MARK: - ExclusionRuleType display helpers

extension ExclusionRuleType {
    var title: String {
        switch self {
        case .app:              return "Applications"
        case .domain:           return "Domains"
        case .contact:          return "Contacts"
        case .windowTitleRegex: return "Window Title Patterns"
        }
    }

    var placeholder: String {
        switch self {
        case .app:              return "App name or bundle ID (e.g. 1Password)"
        case .domain:           return "Domain glob (e.g. *.personal.com)"
        case .contact:          return "Contact name or email"
        case .windowTitleRegex: return "Regex pattern (e.g. Private.*)"
        }
    }

    var footerDescription: String {
        switch self {
        case .app:
            return "Activity in excluded apps is never captured or classified."
        case .domain:
            return "Browser tabs matching excluded domains are skipped. Supports * wildcards."
        case .contact:
            return "Interactions with excluded contacts are not attributed to them."
        case .windowTitleRegex:
            return "Window titles matching the regular expression are excluded from capture."
        }
    }

    var systemImage: String {
        switch self {
        case .app:              return "app.badge"
        case .domain:           return "globe"
        case .contact:          return "person"
        case .windowTitleRegex: return "rectangle.and.text.magnifyingglass"
        }
    }
}
