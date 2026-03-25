import XCTest
@testable import Kerwan

/// Unit tests for the Settings layer:
/// - `SettingsViewModel` default values and mutations
/// - `KerwanPermission` metadata correctness
/// - `PermissionStatus` display properties
/// - `ExclusionRuleType` display helpers
/// - Digest-time string ↔ Date conversion
/// - Regex validation helper
@MainActor
final class SettingsTests: XCTestCase {

    private var vm: SettingsViewModel!

    override func setUp() {
        super.setUp()
        vm = SettingsViewModel(storage: nil)
    }

    override func tearDown() {
        vm = nil
        super.tearDown()
    }

    // MARK: - SettingsViewModel defaults

    func testDefaultCaptureAudioMatchesUserSettingsDefaults() {
        XCTAssertEqual(vm.captureAudio, UserSettings.defaults.captureAudio)
    }

    func testDefaultCaptureAccessibilityMatchesUserSettingsDefaults() {
        XCTAssertEqual(vm.captureAccessibility, UserSettings.defaults.captureAccessibility)
    }

    func testDefaultBillableRateMatchesUserSettingsDefaults() {
        XCTAssertEqual(vm.billableDefaultRate, UserSettings.defaults.billableDefaultRate, accuracy: 0.001)
    }

    func testDefaultConsentModeMatchesUserSettingsDefaults() {
        XCTAssertEqual(vm.consentMode, UserSettings.defaults.consentMode)
    }

    func testDefaultPassphraseInKeychainMatchesUserSettingsDefaults() {
        XCTAssertEqual(vm.passphraseInKeychain, UserSettings.defaults.passphraseInKeychain)
    }

    func testEmailAccountsDefaultsToEmpty() {
        XCTAssertTrue(vm.emailAccounts.isEmpty)
    }

    func testExclusionRulesDefaultsToEmpty() {
        XCTAssertTrue(vm.exclusionRules.isEmpty)
    }

    func testDatabaseFileSizeBytesDefaultsToZero() {
        XCTAssertEqual(vm.databaseFileSizeBytes, 0)
    }

    func testIsExportingDefaultsFalse() {
        XCTAssertFalse(vm.isExporting)
    }

    func testIsConfirmingDeleteAllDefaultsFalse() {
        XCTAssertFalse(vm.isConfirmingDeleteAll)
    }

    func testLastErrorDefaultsToNil() {
        XCTAssertNil(vm.lastError)
    }

    func testLaunchAtLoginDefaultsFalse() {
        // System state may differ; we only test the initial value of the property.
        XCTAssertFalse(vm.launchAtLogin)
    }

    // MARK: - Digest time default

    func testDigestTimeDateDerivesCorrectHourFromDefaults() {
        // Default digestTime is "09:00"
        let comps = Calendar.current.dateComponents([.hour, .minute], from: vm.digestTime)
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 0)
    }

    // MARK: - addExclusionRule

    func testAddExclusionRuleAppendsToList() {
        vm.addExclusionRule(ruleType: .app, pattern: "1Password")
        XCTAssertEqual(vm.exclusionRules.count, 1)
        XCTAssertEqual(vm.exclusionRules.first?.pattern, "1Password")
        XCTAssertEqual(vm.exclusionRules.first?.ruleType, .app)
    }

    func testAddExclusionRuleIgnoresEmptyPattern() {
        vm.addExclusionRule(ruleType: .domain, pattern: "")
        XCTAssertTrue(vm.exclusionRules.isEmpty)
    }

    func testAddExclusionRuleIgnoresWhitespaceOnlyPattern() {
        vm.addExclusionRule(ruleType: .contact, pattern: "   ")
        XCTAssertTrue(vm.exclusionRules.isEmpty)
    }

    func testAddMultipleExclusionRulesPreservesOrder() {
        vm.addExclusionRule(ruleType: .app, pattern: "AppA")
        vm.addExclusionRule(ruleType: .app, pattern: "AppB")
        vm.addExclusionRule(ruleType: .app, pattern: "AppC")
        let patterns = vm.exclusionRules.map { $0.pattern }
        XCTAssertEqual(patterns, ["AppA", "AppB", "AppC"])
    }

    func testAddExclusionRuleDifferentTypes() {
        vm.addExclusionRule(ruleType: .app, pattern: "Zoom")
        vm.addExclusionRule(ruleType: .domain, pattern: "*.personal.com")
        vm.addExclusionRule(ruleType: .contact, pattern: "Jane Smith")
        vm.addExclusionRule(ruleType: .windowTitleRegex, pattern: "Private.*")
        XCTAssertEqual(vm.exclusionRules.count, 4)
    }

    // MARK: - deleteExclusionRules

    func testDeleteExclusionRuleRemovesCorrectItem() {
        vm.addExclusionRule(ruleType: .app, pattern: "AppA")
        vm.addExclusionRule(ruleType: .app, pattern: "AppB")
        vm.addExclusionRule(ruleType: .app, pattern: "AppC")
        // Delete the middle one (index 1 within .app rules)
        vm.deleteExclusionRules(ruleType: .app, at: IndexSet(integer: 1))
        let patterns = vm.exclusionRules.filter { $0.ruleType == .app }.map { $0.pattern }
        XCTAssertEqual(patterns, ["AppA", "AppC"])
    }

    func testDeleteExclusionRuleOnlyAffectsCorrectType() {
        vm.addExclusionRule(ruleType: .app, pattern: "Zoom")
        vm.addExclusionRule(ruleType: .domain, pattern: "*.social.com")
        vm.deleteExclusionRules(ruleType: .app, at: IndexSet(integer: 0))
        XCTAssertTrue(vm.exclusionRules.filter { $0.ruleType == .app }.isEmpty)
        XCTAssertEqual(vm.exclusionRules.filter { $0.ruleType == .domain }.count, 1)
    }

    // MARK: - isValidRegex

    func testValidRegexReturnsTrue() {
        XCTAssertTrue(vm.isValidRegex("Private.*"))
        XCTAssertTrue(vm.isValidRegex("^Meeting:"))
        XCTAssertTrue(vm.isValidRegex("[Ss]tack[Oo]verflow"))
        XCTAssertTrue(vm.isValidRegex(".*"))
    }

    func testInvalidRegexReturnsFalse() {
        XCTAssertFalse(vm.isValidRegex("[unclosed"))
        XCTAssertFalse(vm.isValidRegex("(unmatched"))
        XCTAssertFalse(vm.isValidRegex("*noanchor"))
    }

    func testEmptyStringIsValidRegex() {
        // Empty pattern is technically valid (matches everything).
        XCTAssertTrue(vm.isValidRegex(""))
    }

    // MARK: - disconnectAccount

    func testDisconnectAccountRemovesFromList() {
        let account = EmailAccount(
            id: "acct1",
            address: "user@example.com",
            lastSyncAt: nil,
            status: .connected
        )
        vm.emailAccounts = [account]
        vm.disconnectAccount(account)
        XCTAssertTrue(vm.emailAccounts.isEmpty)
    }

    func testDisconnectUnknownAccountIsNoOp() {
        let known = EmailAccount(id: "a", address: "a@example.com", lastSyncAt: nil, status: .connected)
        let unknown = EmailAccount(id: "b", address: "b@example.com", lastSyncAt: nil, status: .connected)
        vm.emailAccounts = [known]
        vm.disconnectAccount(unknown)
        XCTAssertEqual(vm.emailAccounts.count, 1)
    }

    // MARK: - KerwanPermission metadata

    func testAllPermissionCasesCount() {
        XCTAssertEqual(KerwanPermission.allCases.count, 4)
    }

    func testPermissionTitlesAreNonEmpty() {
        for p in KerwanPermission.allCases {
            XCTAssertFalse(p.title.isEmpty, "\(p) title must not be empty")
        }
    }

    func testPermissionDescriptionsAreNonEmpty() {
        for p in KerwanPermission.allCases {
            XCTAssertFalse(p.permissionDescription.isEmpty, "\(p) description must not be empty")
        }
    }

    func testPermissionSystemImagesAreNonEmpty() {
        for p in KerwanPermission.allCases {
            XCTAssertFalse(p.systemImage.isEmpty, "\(p) systemImage must not be empty")
        }
    }

    func testPermissionSettingsURLsAreValid() {
        for p in KerwanPermission.allCases {
            let url = p.settingsURL
            XCTAssertFalse(url.absoluteString.isEmpty, "\(p) settingsURL must not be empty")
        }
    }

    // MARK: - PermissionStatus display properties

    func testPermissionStatusLabelsAreNonEmpty() {
        let statuses: [PermissionStatus] = [.granted, .denied, .notDetermined, .restricted, .unknown]
        for s in statuses {
            XCTAssertFalse(s.label.isEmpty, "\(s) label must not be empty")
        }
    }

    func testPermissionStatusSystemImagesAreNonEmpty() {
        let statuses: [PermissionStatus] = [.granted, .denied, .notDetermined, .restricted, .unknown]
        for s in statuses {
            XCTAssertFalse(s.systemImage.isEmpty, "\(s) systemImage must not be empty")
        }
    }

    // MARK: - ExclusionRuleType display helpers

    func testExclusionRuleTypeTitlesAreNonEmpty() {
        for t in ExclusionRuleType.allCases {
            XCTAssertFalse(t.title.isEmpty, "\(t) title must not be empty")
        }
    }

    func testExclusionRuleTypePlaceholdersAreNonEmpty() {
        for t in ExclusionRuleType.allCases {
            XCTAssertFalse(t.placeholder.isEmpty, "\(t) placeholder must not be empty")
        }
    }

    func testExclusionRuleTypeFooterDescriptionsAreNonEmpty() {
        for t in ExclusionRuleType.allCases {
            XCTAssertFalse(t.footerDescription.isEmpty, "\(t) footerDescription must not be empty")
        }
    }

    func testExclusionRuleTypeSystemImagesAreNonEmpty() {
        for t in ExclusionRuleType.allCases {
            XCTAssertFalse(t.systemImage.isEmpty, "\(t) systemImage must not be empty")
        }
    }

    // MARK: - EmailAccount model

    func testEmailAccountIdentifiableIdIsStable() {
        let a = EmailAccount(id: "x1", address: "x@example.com", lastSyncAt: nil, status: .connected)
        XCTAssertEqual(a.id, "x1")
    }

    func testEmailSyncStatusRawValues() {
        XCTAssertEqual(EmailSyncStatus.connected.rawValue, "connected")
        XCTAssertEqual(EmailSyncStatus.syncing.rawValue, "syncing")
        XCTAssertEqual(EmailSyncStatus.error.rawValue, "error")
        XCTAssertEqual(EmailSyncStatus.disconnected.rawValue, "disconnected")
    }
}
